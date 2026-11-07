import CryptoKit
import Foundation
import OhiaCore
import SwiftData

public enum ManualProjectConfigurationCheckpoint: String, Codable, Sendable, Equatable {
    case beforeEvaluation
    case beforeCommit
}

public enum ManualProjectConfigurationServiceError: Error, Sendable, Equatable {
    case projectNotFound(UUID)
    case projectIdentityMismatch
    case nameCollision(String)
    case invalidEarlierBoundary
    case invalidConfiguration(MailProjectValidationReport)
    case invalidAccountScope([UUID])
    case invalidManualDecision(UUID)
    case missingManualDecisionTarget(kind: MailProjectDecisionTargetKind, id: UUID)
    case duplicateManualDecision(String)
    case unstableSourceSnapshot
    case malformedDraft
    case malformedProvenance
}

public actor ManualProjectConfigurationService {
    private static let draftPayloadVersion = 1

    private let container: ModelContainer
    private let textReader: any ProjectTextFileReading
    private let notificationCenter: NotificationCenter
    private let now: @Sendable () -> Date
    private let beforeConfigurationSave: @Sendable () throws -> Void
    private let beforeWriteAuthority: @Sendable () -> Void
    private let beforeTransactionPersist: @Sendable () throws -> Void
    private let suspension: @Sendable (ManualProjectConfigurationCheckpoint) async throws -> Void
    private var capturedNewMailBoundaries: [UUID: Date] = [:]

    public init(
        container: ModelContainer,
        textReader: any ProjectTextFileReading,
        notificationCenter: NotificationCenter = .default,
        now: @escaping @Sendable () -> Date = { .now },
        beforeConfigurationSave: @escaping @Sendable () throws -> Void = {},
        suspension: @escaping @Sendable (ManualProjectConfigurationCheckpoint) async throws -> Void = { _ in }
    ) {
        self.container = container
        self.textReader = textReader
        self.notificationCenter = notificationCenter
        self.now = now
        self.beforeConfigurationSave = beforeConfigurationSave
        self.beforeWriteAuthority = {}
        self.beforeTransactionPersist = {}
        self.suspension = suspension
    }

    init(
        container: ModelContainer,
        textReader: any ProjectTextFileReading,
        notificationCenter: NotificationCenter = .default,
        now: @escaping @Sendable () -> Date = { .now },
        beforeConfigurationSave: @escaping @Sendable () throws -> Void = {},
        suspension: @escaping @Sendable (ManualProjectConfigurationCheckpoint) async throws -> Void = { _ in },
        _testBeforeWriteAuthority: @escaping @Sendable () -> Void = {},
        _testBeforeTransactionPersist: @escaping @Sendable () throws -> Void
    ) {
        self.container = container
        self.textReader = textReader
        self.notificationCenter = notificationCenter
        self.now = now
        self.beforeConfigurationSave = beforeConfigurationSave
        self.beforeWriteAuthority = _testBeforeWriteAuthority
        self.beforeTransactionPersist = _testBeforeTransactionPersist
        self.suspension = suspension
    }

    public func saveDraft(_ draft: MailProjectConfigurationSnapshot) throws {
        try ManualProjectWriteAuthority.withLock {
            let configuration = try canonicalizedDraft(draft)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = String(decoding: try encoder.encode(configuration), as: UTF8.self)
            let context = freshContext()
            var committed = false
            defer {
                if committed == false { context.rollback() }
            }

            let rows = try context.fetch(FetchDescriptor<MailProjectConfigurationDraft>())
                .sorted { $0.id.uuidString < $1.id.uuidString }
            let timestamp = now()
            let row: MailProjectConfigurationDraft
            if let existing = rows.first {
                row = existing
                row.targetProjectID = configuration.existingProjectID
                row.baseRevision = configuration.baseConfigurationRevision
                row.payloadVersion = Self.draftPayloadVersion
                row.payloadJSON = payload
                row.updatedAt = timestamp
            } else {
                row = MailProjectConfigurationDraft(
                    targetProjectID: configuration.existingProjectID,
                    baseRevision: configuration.baseConfigurationRevision,
                    payloadVersion: Self.draftPayloadVersion,
                    payloadJSON: payload,
                    createdAt: timestamp
                )
                context.insert(row)
            }
            for duplicate in rows.dropFirst() { context.delete(duplicate) }
            try context.save()
            committed = true
        }
    }

    public func loadDraft() throws -> MailProjectConfigurationDraftSnapshot? {
        try ManualProjectWriteAuthority.withLock {
            let context = freshContext()
            guard let row = try context.fetch(FetchDescriptor<MailProjectConfigurationDraft>())
                .sorted(by: { $0.id.uuidString < $1.id.uuidString })
                .first else {
                return nil
            }
            return draftSnapshot(row)
        }
    }

    public func discardDraft() throws {
        try ManualProjectWriteAuthority.withLock {
            let context = freshContext()
            let rows = try context.fetch(FetchDescriptor<MailProjectConfigurationDraft>())
            guard rows.isEmpty == false else { return }
            for row in rows { context.delete(row) }
            do {
                try context.save()
                capturedNewMailBoundaries.removeAll()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    public func preview(
        _ draft: MailProjectConfigurationSnapshot
    ) async throws -> MailProjectPreview {
        let configuration = try canonicalizedDraft(draft)
        try await suspension(.beforeEvaluation)
        return try prepare(configuration, boundaryPolicy: .ordinary).preview
    }

    public func save(
        _ draft: MailProjectConfigurationSnapshot,
        reviewedPreviewFingerprint: String
    ) async throws -> MailProjectSaveOutcome {
        let configuration = try canonicalizedDraft(draft)
        try await suspension(.beforeEvaluation)
        let prepared = try prepare(configuration, boundaryPolicy: .ordinary)
        if prepared.draftReviewState.isConflict {
            return .reviewRequired(prepared.preview)
        }
        guard prepared.preview.fingerprint == reviewedPreviewFingerprint else {
            return .reviewRequired(prepared.preview)
        }

        try await suspension(.beforeCommit)
        try beforeConfigurationSave()
        let finalPrepared = try prepare(configuration, boundaryPolicy: .ordinary)
        if finalPrepared.draftReviewState.isConflict {
            return .reviewRequired(finalPrepared.preview)
        }
        guard finalPrepared.preview.fingerprint == reviewedPreviewFingerprint else {
            return .reviewRequired(finalPrepared.preview)
        }
        guard finalPrepared.sourceFreshnessStamp == prepared.sourceFreshnessStamp else {
            return .reviewRequired(finalPrepared.preview)
        }
        beforeWriteAuthority()
        let finalization = try ManualProjectWriteAuthority.withLock {
            let context = freshContext()
            var result: FinalizationResult?
            try context.transaction {
                guard try sourceFreshnessStamp(in: context) == finalPrepared.sourceFreshnessStamp else {
                    result = .stale
                    return
                }
                result = .committed(try commit(finalPrepared, in: context))
            }
            guard let result else {
                preconditionFailure("The final project transaction must produce a result.")
            }
            return result
        }
        if case .stale = finalization {
            return .reviewRequired(try prepare(configuration, boundaryPolicy: .ordinary).preview)
        }
        return finish(finalization)
    }

    public func includeEarlierMail(
        projectID: UUID,
        proposedBoundary: Date?,
        reviewedPreviewFingerprint: String
    ) async throws -> MailProjectSaveOutcome {
        let live = try loadLiveConfiguration(projectID: projectID)
        if live.automaticIntakeStartAt == proposedBoundary {
            return .saved(
                projectID: projectID,
                configurationRevision: live.baseConfigurationRevision
            )
        }
        guard boundary(proposedBoundary, expandsBackwardFrom: live.automaticIntakeStartAt) else {
            throw ManualProjectConfigurationServiceError.invalidEarlierBoundary
        }
        let proposed = replacingBoundary(in: live, with: proposedBoundary)

        try await suspension(.beforeEvaluation)
        let prepared = try prepare(proposed, boundaryPolicy: .includeEarlier)
        guard prepared.preview.fingerprint == reviewedPreviewFingerprint else {
            return .reviewRequired(prepared.preview)
        }

        try await suspension(.beforeCommit)
        try beforeConfigurationSave()
        let finalLive = try loadLiveConfiguration(projectID: projectID)
        guard boundary(
            proposedBoundary,
            expandsBackwardFrom: finalLive.automaticIntakeStartAt
        ) else {
            if finalLive.automaticIntakeStartAt == proposedBoundary {
                return .saved(
                    projectID: projectID,
                    configurationRevision: finalLive.baseConfigurationRevision
                )
            }
            throw ManualProjectConfigurationServiceError.invalidEarlierBoundary
        }
        let finalPrepared = try prepare(
            replacingBoundary(in: finalLive, with: proposedBoundary),
            boundaryPolicy: .includeEarlier
        )
        guard finalPrepared.preview.fingerprint == reviewedPreviewFingerprint else {
            return .reviewRequired(finalPrepared.preview)
        }
        beforeWriteAuthority()
        let finalization = try ManualProjectWriteAuthority.withLock {
            let context = freshContext()
            var result: FinalizationResult?
            try context.transaction {
                guard try sourceFreshnessStamp(in: context) == finalPrepared.sourceFreshnessStamp else {
                    result = .stale
                    return
                }
                result = .committed(try commit(finalPrepared, in: context))
            }
            guard let result else {
                preconditionFailure("The final project transaction must produce a result.")
            }
            return result
        }
        if case .stale = finalization {
            let freshLive = try loadLiveConfiguration(projectID: projectID)
            let fresh = try prepare(
                replacingBoundary(in: freshLive, with: proposedBoundary),
                boundaryPolicy: .includeEarlier
            )
            return .reviewRequired(fresh.preview)
        }
        return finish(finalization)
    }

    // MARK: - Preparation

    private func prepare(
        _ proposed: MailProjectConfigurationSnapshot,
        boundaryPolicy: BoundaryPolicy
    ) throws -> PreparedConfiguration {
        for _ in 0..<2 {
            let context = freshContext()
            let before = try sourceFreshnessStamp(in: context)
            let prepared = try prepare(proposed, boundaryPolicy: boundaryPolicy, in: context)
            let after = try sourceFreshnessStamp(in: freshContext())
            if before == after, prepared.sourceFreshnessStamp == after {
                return prepared
            }
        }
        throw ManualProjectConfigurationServiceError.unstableSourceSnapshot
    }

    private func prepare(
        _ proposed: MailProjectConfigurationSnapshot,
        boundaryPolicy: BoundaryPolicy,
        in context: ModelContext
    ) throws -> PreparedConfiguration {
        let canonical = try canonicalConfiguration(
            proposed,
            boundaryPolicy: boundaryPolicy,
            in: context
        )
        let committedConfiguration = try canonical.existingProjectID.map {
            try loadLiveConfiguration(projectID: $0, in: context)
        }
        let selectedValues = selectedValuesByFacet(canonical)
        let catalog = try ManualProjectRuleCatalog(modelContext: context).snapshot(
            selectedValuesByFacet: selectedValues
        )
        try validateAccountScope(canonical, catalog: catalog)
        let validation = ManualProjectConfigurationValidator.validate(
            configuration: canonical,
            catalog: catalog
        )
        guard validation.isValid else {
            throw ManualProjectConfigurationServiceError.invalidConfiguration(validation)
        }
        try validateManualDecisionStructure(canonical)

        let messages = try context.fetch(FetchDescriptor<Message>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let threads = try context.fetch(FetchDescriptor<MessageThread>())
        try validateManualDecisionTargets(
            canonical,
            messageIDs: Set(messages.map(\.id)),
            threadIDs: Set(threads.map(\.id))
        )
        let builder = ManualProjectMessageSnapshotBuilder(textReader: textReader)
        let messageSnapshots = try messages.map(builder.snapshot)
        let currentRows = try context.fetch(FetchDescriptor<MailProjectMembership>())
            .filter { $0.projectID == canonical.projectID }
            .sorted { $0.messageID.uuidString < $1.messageID.uuidString }
        let currentMemberships = try currentRows.map(membershipSnapshot)
        let currentByMessageID = Dictionary(
            uniqueKeysWithValues: currentMemberships.map { ($0.messageID, $0) }
        )
        let dependencies = ManualProjectDependencyIndex.dependencySet(for: canonical)

        let evaluatedAt = now()
        var automaticMatchCount = 0
        var evaluated: [MailProjectEvaluatedMessage] = []
        evaluated.reserveCapacity(messageSnapshots.count)
        for message in messageSnapshots {
            let automatic = ManualProjectRuleEvaluator.evaluate(
                configuration: canonical,
                message: message,
                validationReport: validation
            )
            if case .member = automatic { automaticMatchCount += 1 }
            let final = ManualProjectMembershipDecision.resolve(
                messageID: message.id,
                threadID: message.threadID,
                decisions: canonical.manualDecisions,
                automatic: automatic
            )
            evaluated.append(MailProjectEvaluatedMessage(
                messageID: message.id,
                finalDecision: final,
                sourceFingerprint: ManualProjectFingerprint.messageSourceFingerprint(
                    message,
                    dependencySet: dependencies
                ),
                evaluatedAt: evaluatedAt
            ))
        }

        let proposedByMessageID: [UUID: MailProjectPreviewMembership] = Dictionary(
            uniqueKeysWithValues: evaluated.compactMap { item in
                guard case let .included(source, provenance) = item.finalDecision else { return nil }
                return (item.messageID, MailProjectPreviewMembership(
                    messageID: item.messageID,
                    source: source,
                    provenance: provenance,
                    ruleDetails: ruleDetails(
                        for: provenance,
                        configuration: canonical,
                        side: .proposed
                    )
                ))
            }
        )
        let currentPreviewByMessageID = Dictionary(
            uniqueKeysWithValues: currentMemberships.map { membership in
                (membership.messageID, MailProjectPreviewMembership(
                    messageID: membership.messageID,
                    source: membership.source,
                    provenance: membership.provenance,
                    ruleDetails: committedConfiguration.flatMap {
                        ruleDetails(
                            for: membership.provenance,
                            configuration: $0,
                            side: .committed
                        )
                    }
                ))
            }
        )
        let added = proposedByMessageID.compactMap { entry -> MailProjectPreviewMembership? in
            let (messageID, membership) = entry
            return currentByMessageID[messageID] == nil ? membership : nil
        }
        let removed = currentPreviewByMessageID.compactMap { entry -> MailProjectPreviewMembership? in
            let (messageID, membership) = entry
            return proposedByMessageID[messageID] == nil ? membership : nil
        }
        let unchangedExceptions = proposedByMessageID.compactMap { entry -> MailProjectPreviewMembership? in
            let (messageID, membership) = entry
            guard currentByMessageID[messageID] != nil,
                  membership.provenance.isExceptionToAutomaticRules else {
                return nil
            }
            return membership
        }
        let candidateRevision = canonical.existingProjectID == nil
            ? 1
            : canonical.baseConfigurationRevision + 1
        let draftReviewState = try draftReviewState(
            configuration: canonical,
            policy: boundaryPolicy.draftParticipationPolicy,
            in: context
        )
        let fingerprint = try previewFingerprint(
            configuration: canonical,
            catalog: catalog,
            messages: messageSnapshots,
            currentMemberships: currentMemberships,
            currentRuleDetailsByMessageID: currentPreviewByMessageID.mapValues(\.ruleDetails),
            candidateRevision: candidateRevision,
            draftReviewState: draftReviewState
        )
        let eligibleCount = messageSnapshots.count { isAutomaticallyEligible($0, for: canonical) }
        let warning = broadRuleWarning(
            configuration: canonical,
            exactMatchCount: automaticMatchCount,
            eligibleMessageCount: eligibleCount
        )
        let preview = MailProjectPreview(
            projectID: canonical.projectID,
            candidateRevision: candidateRevision,
            fingerprint: fingerprint,
            willBeAdded: added,
            willBeRemoved: removed,
            unchangedExceptions: unchangedExceptions,
            exactMatchCount: automaticMatchCount,
            broadRuleWarning: warning,
            health: .healthy
        )
        return PreparedConfiguration(
            configuration: canonical,
            preview: preview,
            evaluated: evaluated,
            affectedMessageIDs: Set(currentByMessageID.keys).union(proposedByMessageID.keys),
            draftReviewState: draftReviewState,
            sourceFreshnessStamp: try sourceFreshnessStamp(in: context)
        )
    }

    private func canonicalConfiguration(
        _ proposed: MailProjectConfigurationSnapshot,
        boundaryPolicy: BoundaryPolicy,
        in context: ModelContext
    ) throws -> MailProjectConfigurationSnapshot {
        guard proposed.existingProjectID == nil || proposed.existingProjectID == proposed.projectID else {
            throw ManualProjectConfigurationServiceError.projectIdentityMismatch
        }
        let normalizedName = try MailProject.normalizedName(proposed.displayName)
        let projects = try context.fetch(FetchDescriptor<MailProject>())
        if let collision = projects.first(where: {
            $0.normalizedName == normalizedName && $0.id != proposed.existingProjectID
        }) {
            _ = collision
            throw ManualProjectConfigurationServiceError.nameCollision(normalizedName)
        }

        let boundary: Date?
        let baseConfigurationRevision: Int
        if let existingProjectID = proposed.existingProjectID {
            guard let live = projects.first(where: { $0.id == existingProjectID }) else {
                throw ManualProjectConfigurationServiceError.projectNotFound(existingProjectID)
            }
            boundary = boundaryPolicy == .ordinary
                ? live.automaticIntakeStartAt
                : proposed.automaticIntakeStartAt
            baseConfigurationRevision = live.configurationRevision
        } else {
            guard projects.contains(where: { $0.id == proposed.projectID }) == false else {
                throw ManualProjectConfigurationServiceError.projectIdentityMismatch
            }
            boundary = proposed.automaticIntakeStartAt
            baseConfigurationRevision = proposed.baseConfigurationRevision
        }
        return MailProjectConfigurationSnapshot(
            projectID: proposed.projectID,
            existingProjectID: proposed.existingProjectID,
            displayName: proposed.displayName,
            accountIDs: proposed.accountIDs,
            automaticIntakeStartAt: boundary,
            baseConfigurationRevision: baseConfigurationRevision,
            groups: proposed.groups.sorted(by: snapshotGroupOrder),
            manualDecisions: proposed.manualDecisions.sorted(by: snapshotDecisionOrder)
        )
    }

    // MARK: - Commit

    private func commit(
        _ prepared: PreparedConfiguration,
        in context: ModelContext
    ) throws -> CommitReceipt {
        let projection = try prepared.evaluated.compactMap { item -> ProjectionReplacement? in
            guard case let .included(source, provenance) = item.finalDecision else { return nil }
            return ProjectionReplacement(
                messageID: item.messageID,
                source: source,
                provenance: provenance,
                provenanceJSON: try encodeProvenance(provenance),
                sourceFingerprint: item.sourceFingerprint,
                evaluatedAt: item.evaluatedAt
            )
        }
        let canonical = prepared.configuration
        let timestamp = now()
        let project: MailProject
        if let existingProjectID = canonical.existingProjectID {
            guard let live = try context.fetch(FetchDescriptor<MailProject>())
                .first(where: { $0.id == existingProjectID }) else {
                throw ManualProjectConfigurationServiceError.projectNotFound(existingProjectID)
            }
            project = live
            try project.rename(to: canonical.displayName, updatedAt: timestamp)
            try project.replaceAccountIDs(Array(canonical.accountIDs))
            project.automaticIntakeStartAt = canonical.automaticIntakeStartAt
            project.configurationRevision = prepared.preview.candidateRevision
            project.health = .healthy
            project.lastMembershipError = nil
            project.updatedAt = timestamp
        } else {
            project = try MailProject(
                id: canonical.projectID,
                displayName: canonical.displayName,
                accountIDs: Array(canonical.accountIDs),
                automaticIntakeStartAt: canonical.automaticIntakeStartAt,
                configurationRevision: prepared.preview.candidateRevision,
                health: .healthy,
                createdAt: timestamp
            )
            context.insert(project)
        }

        for group in project.ruleGroups { context.delete(group) }
        project.ruleGroups = []
        for snapshot in canonical.groups {
            let group = MailProjectRuleGroup(
                id: snapshot.id,
                kind: snapshot.kind,
                sortIndex: snapshot.sortIndex
            )
            group.project = project
            group.conditions = try snapshot.conditions.sorted(by: snapshotConditionOrder).map { condition in
                let row = try MailProjectRuleCondition(
                    id: condition.id,
                    facet: condition.facet,
                    polarity: condition.polarity,
                    quantifier: condition.quantifier,
                    values: condition.values,
                    correspondentRole: condition.correspondentRole,
                    keywordScopes: Array(condition.keywordScopes),
                    keywordOperator: condition.keywordOperator,
                    sortIndex: condition.sortIndex
                )
                row.group = group
                return row
            }
            context.insert(group)
            project.ruleGroups.append(group)
        }

        let decisions = try context.fetch(FetchDescriptor<MailProjectDecision>())
            .filter { $0.projectID == canonical.projectID }
        let createdAtByID = Dictionary(uniqueKeysWithValues: decisions.map { decision in
            (decision.id, ExistingDecisionCreation(
                key: decision.decisionKey,
                createdAt: decision.createdAt
            ))
        })
        let createdAtByKey = Dictionary(uniqueKeysWithValues: decisions.map { decision in
            (decision.decisionKey, decision.createdAt)
        })
        for row in decisions { context.delete(row) }
        for snapshot in canonical.manualDecisions {
            let key = MailProjectDecision.key(
                projectID: canonical.projectID,
                targetKind: snapshot.targetKind,
                targetID: snapshot.targetID
            )
            let createdAt: Date
            if let existing = createdAtByID[snapshot.id], existing.key == key {
                createdAt = existing.createdAt
            } else if let existing = createdAtByKey[key] {
                createdAt = existing
            } else {
                createdAt = snapshot.updatedAt
            }
            context.insert(MailProjectDecision(
                id: snapshot.id,
                projectID: canonical.projectID,
                targetKind: snapshot.targetKind,
                targetID: snapshot.targetID,
                decision: snapshot.decision,
                createdAt: createdAt,
                updatedAt: snapshot.updatedAt
            ))
        }

        let oldMemberships = try context.fetch(FetchDescriptor<MailProjectMembership>())
            .filter { $0.projectID == canonical.projectID }
        for row in oldMemberships { context.delete(row) }
        for replacement in projection.sorted(by: { $0.messageID.uuidString < $1.messageID.uuidString }) {
            context.insert(try MailProjectMembership(
                projectID: canonical.projectID,
                messageID: replacement.messageID,
                configurationRevision: prepared.preview.candidateRevision,
                source: replacement.source,
                matchingGroupID: replacement.provenance.rule?.matchingGroupID,
                matchingConditionIDs: Array(replacement.provenance.rule?.matchingConditionIDs ?? []),
                provenanceJSON: replacement.provenanceJSON,
                sourceFingerprint: replacement.sourceFingerprint,
                evaluatedAt: replacement.evaluatedAt
            ))
        }

        if case let .matching(reviewedDraft) = prepared.draftReviewState {
            let rows = try context.fetch(FetchDescriptor<MailProjectConfigurationDraft>())
            if let row = rows.first(where: { $0.id == reviewedDraft.id }),
               try durableDraftState(row) == reviewedDraft {
                context.delete(row)
            }
        }

        // The caller owns one fresh context and one ModelContext transaction;
        // returning from that transaction is the sole persistence boundary.
        try beforeTransactionPersist()
        return CommitReceipt(
            projectID: canonical.projectID,
            configurationRevision: prepared.preview.candidateRevision,
            affectedMessageIDs: prepared.affectedMessageIDs
        )
    }

    private func finish(_ result: FinalizationResult) -> MailProjectSaveOutcome {
        switch result {
        case let .reviewRequired(preview):
            return .reviewRequired(preview)
        case let .idempotent(projectID, configurationRevision):
            return .saved(
                projectID: projectID,
                configurationRevision: configurationRevision
            )
        case let .committed(receipt):
            capturedNewMailBoundaries[receipt.projectID] = nil
            notificationCenter.post(
                name: .ohiaManualProjectMembershipDidChange,
                object: nil,
                userInfo: ManualProjectMembershipNotificationCoding.userInfo(
                    projectIDs: [receipt.projectID],
                    messageIDs: receipt.affectedMessageIDs,
                    configurationRevision: receipt.configurationRevision
                )
            )
            return .saved(
                projectID: receipt.projectID,
                configurationRevision: receipt.configurationRevision
            )
        case .stale:
            preconditionFailure("A stale finalization must be recomputed outside the write authority.")
        }
    }

    // MARK: - Durable mapping

    private func canonicalizedDraft(
        _ draft: MailProjectConfigurationSnapshot
    ) throws -> MailProjectConfigurationSnapshot {
        try canonicalizedDraft(draft, in: freshContext())
    }

    private func canonicalizedDraft(
        _ draft: MailProjectConfigurationSnapshot,
        in context: ModelContext
    ) throws -> MailProjectConfigurationSnapshot {
        var boundary = draft.automaticIntakeStartAt
        var baseRevision = draft.baseConfigurationRevision
        if let existingProjectID = draft.existingProjectID {
            if let live = try context.fetch(FetchDescriptor<MailProject>())
                .first(where: { $0.id == existingProjectID }) {
                boundary = live.automaticIntakeStartAt
                baseRevision = live.configurationRevision
            }
        } else if draft.automaticIntakeStartAt != nil {
            if let stored = try persistedDraftConfiguration(in: context),
               stored.projectID == draft.projectID,
               stored.existingProjectID == nil,
               let storedBoundary = stored.automaticIntakeStartAt {
                boundary = storedBoundary
            } else if let captured = capturedNewMailBoundaries[draft.projectID] {
                boundary = captured
            } else {
                let captured = now()
                capturedNewMailBoundaries[draft.projectID] = captured
                boundary = captured
            }
        }
        return MailProjectConfigurationSnapshot(
            projectID: draft.projectID,
            existingProjectID: draft.existingProjectID,
            displayName: draft.displayName,
            accountIDs: draft.accountIDs,
            automaticIntakeStartAt: boundary,
            baseConfigurationRevision: baseRevision,
            groups: draft.groups.sorted(by: snapshotGroupOrder),
            manualDecisions: draft.manualDecisions.sorted(by: snapshotDecisionOrder)
        )
    }

    private func persistedDraftConfiguration(
        in context: ModelContext
    ) throws -> MailProjectConfigurationSnapshot? {
        guard let row = try context.fetch(FetchDescriptor<MailProjectConfigurationDraft>())
            .sorted(by: { $0.id.uuidString < $1.id.uuidString })
            .first else {
            return nil
        }
        guard row.payloadVersion == Self.draftPayloadVersion,
              let data = row.payloadJSON.data(using: .utf8),
              let configuration = try? JSONDecoder().decode(
                MailProjectConfigurationSnapshot.self,
                from: data
              ) else {
            throw ManualProjectConfigurationServiceError.malformedDraft
        }
        return configuration
    }

    private func loadLiveConfiguration(
        projectID: UUID
    ) throws -> MailProjectConfigurationSnapshot {
        try loadLiveConfiguration(projectID: projectID, in: freshContext())
    }

    private func loadLiveConfiguration(
        projectID: UUID,
        in context: ModelContext
    ) throws -> MailProjectConfigurationSnapshot {
        guard let project = try context.fetch(FetchDescriptor<MailProject>())
            .first(where: { $0.id == projectID }) else {
            throw ManualProjectConfigurationServiceError.projectNotFound(projectID)
        }
        let groups = try project.ruleGroups.sorted(by: persistedGroupOrder).map { group in
            MailProjectRuleGroupSnapshot(
                id: group.id,
                kind: group.kind,
                sortIndex: group.sortIndex,
                conditions: try group.conditions.sorted(by: persistedConditionOrder).map { condition in
                    MailProjectRuleConditionSnapshot(
                        id: condition.id,
                        facet: condition.facet,
                        polarity: condition.polarity,
                        quantifier: condition.quantifier,
                        values: try condition.values(),
                        correspondentRole: condition.correspondentRole,
                        keywordScopes: Set(try condition.keywordScopes()),
                        keywordOperator: condition.keywordOperator,
                        sortIndex: condition.sortIndex
                    )
                }
            )
        }
        let decisions = try context.fetch(FetchDescriptor<MailProjectDecision>())
            .filter { $0.projectID == projectID }
            .sorted(by: persistedDecisionOrder)
            .map { decision in
                MailProjectDecisionSnapshot(
                    id: decision.id,
                    projectID: decision.projectID,
                    targetKind: decision.targetKind,
                    targetID: decision.targetID,
                    decision: decision.decision,
                    updatedAt: decision.updatedAt
                )
            }
        return MailProjectConfigurationSnapshot(
            projectID: project.id,
            existingProjectID: project.id,
            displayName: project.displayName,
            accountIDs: Set(try project.accountIDs()),
            automaticIntakeStartAt: project.automaticIntakeStartAt,
            baseConfigurationRevision: project.configurationRevision,
            groups: groups,
            manualDecisions: decisions
        )
    }

    private func draftSnapshot(
        _ row: MailProjectConfigurationDraft
    ) -> MailProjectConfigurationDraftSnapshot {
        MailProjectConfigurationDraftSnapshot(
            id: row.id,
            targetProjectID: row.targetProjectID,
            baseRevision: row.baseRevision,
            payloadVersion: row.payloadVersion,
            payloadJSON: row.payloadJSON,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    private func draftReviewState(
        configuration: MailProjectConfigurationSnapshot,
        policy: DraftParticipationPolicy,
        in context: ModelContext
    ) throws -> DraftReviewState {
        guard policy == .ordinaryExact else { return .none }
        let rows = try context.fetch(FetchDescriptor<MailProjectConfigurationDraft>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for row in rows {
            guard draftRowMayTarget(row, configuration: configuration) else { continue }
            let decoded = try decodedDraftConfiguration(row)
            guard decodedDraftTargets(decoded, configuration: configuration) else { continue }
            let durableState = try durableDraftState(row, decodedConfiguration: decoded)
            return decoded == configuration
                ? .matching(durableState)
                : .conflicting(durableState)
        }
        return .none
    }

    private func durableDraftState(
        _ row: MailProjectConfigurationDraft
    ) throws -> DurableDraftState {
        try durableDraftState(row, decodedConfiguration: decodedDraftConfiguration(row))
    }

    private func durableDraftState(
        _ row: MailProjectConfigurationDraft,
        decodedConfiguration configuration: MailProjectConfigurationSnapshot
    ) throws -> DurableDraftState {
        var encoder = ServiceFingerprintEncoder()
        encoder.append("row.id", row.id.uuidString)
        encoder.append("row.targetProjectID", row.targetProjectID?.uuidString ?? "<nil>")
        encoder.append("row.baseRevision", String(row.baseRevision))
        encoder.append("row.payloadVersion", String(row.payloadVersion))
        appendExactDraftConfiguration(configuration, to: &encoder)
        return DurableDraftState(id: row.id, fingerprint: encoder.digest)
    }

    private func decodedDraftConfiguration(
        _ row: MailProjectConfigurationDraft
    ) throws -> MailProjectConfigurationSnapshot {
        guard row.payloadVersion == Self.draftPayloadVersion,
              let data = row.payloadJSON.data(using: .utf8),
              let configuration = try? JSONDecoder().decode(
                MailProjectConfigurationSnapshot.self,
                from: data
              ) else {
            throw ManualProjectConfigurationServiceError.malformedDraft
        }
        return configuration
    }

    private func draftRowMayTarget(
        _ row: MailProjectConfigurationDraft,
        configuration: MailProjectConfigurationSnapshot
    ) -> Bool {
        if let existingProjectID = configuration.existingProjectID {
            return row.targetProjectID == existingProjectID
        }
        return row.targetProjectID == nil
    }

    private func decodedDraftTargets(
        _ draft: MailProjectConfigurationSnapshot,
        configuration: MailProjectConfigurationSnapshot
    ) -> Bool {
        draft.projectID == configuration.projectID
            && draft.existingProjectID == configuration.existingProjectID
    }

    private func appendExactDraftConfiguration(
        _ configuration: MailProjectConfigurationSnapshot,
        to encoder: inout ServiceFingerprintEncoder
    ) {
        encoder.append("configuration.projectID", configuration.projectID.uuidString)
        encoder.append(
            "configuration.existingProjectID",
            configuration.existingProjectID?.uuidString ?? "<nil>"
        )
        encoder.append("configuration.displayName", configuration.displayName)
        let accountIDs = configuration.accountIDs.map(\.uuidString).sorted()
        encoder.append("configuration.accountIDCount", String(accountIDs.count))
        for accountID in accountIDs {
            encoder.append("configuration.accountID", accountID)
        }
        encoder.append(
            "configuration.automaticIntakeStartAt",
            configuration.automaticIntakeStartAt.map(dateFingerprintValue) ?? "<nil>"
        )
        encoder.append(
            "configuration.baseConfigurationRevision",
            String(configuration.baseConfigurationRevision)
        )

        let groups = configuration.groups.sorted(by: snapshotGroupOrder)
        encoder.append("configuration.groupCount", String(groups.count))
        for group in groups {
            encoder.append("group.id", group.id.uuidString)
            encoder.append("group.kind", group.kind.rawValue)
            encoder.append("group.sortIndex", String(group.sortIndex))
            let conditions = group.conditions.sorted(by: snapshotConditionOrder)
            encoder.append("group.conditionCount", String(conditions.count))
            for condition in conditions {
                encoder.append("condition.id", condition.id.uuidString)
                encoder.append("condition.facet", condition.facet.rawValue)
                encoder.append("condition.polarity", condition.polarity.rawValue)
                encoder.append("condition.quantifier", condition.quantifier.rawValue)
                let values = condition.values.sorted()
                encoder.append("condition.valueCount", String(values.count))
                for value in values {
                    encoder.append("condition.value", value)
                }
                encoder.append(
                    "condition.correspondentRole",
                    condition.correspondentRole?.rawValue ?? "<nil>"
                )
                let keywordScopes = condition.keywordScopes.map(\.rawValue).sorted()
                encoder.append("condition.keywordScopeCount", String(keywordScopes.count))
                for keywordScope in keywordScopes {
                    encoder.append("condition.keywordScope", keywordScope)
                }
                encoder.append(
                    "condition.keywordOperator",
                    condition.keywordOperator?.rawValue ?? "<nil>"
                )
                encoder.append("condition.sortIndex", String(condition.sortIndex))
            }
        }

        let decisions = configuration.manualDecisions.sorted(by: snapshotDecisionOrder)
        encoder.append("configuration.decisionCount", String(decisions.count))
        for decision in decisions {
            encoder.append("decision.id", decision.id.uuidString)
            encoder.append("decision.projectID", decision.projectID.uuidString)
            encoder.append("decision.targetKind", decision.targetKind.rawValue)
            encoder.append("decision.targetID", decision.targetID.uuidString)
            encoder.append("decision.value", decision.decision.rawValue)
            encoder.append("decision.updatedAt", dateFingerprintValue(decision.updatedAt))
        }
    }

    private func dateFingerprintValue(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern)
    }

    private func sourceFreshnessStamp(in context: ModelContext) throws -> String {
        var encoder = ServiceFingerprintEncoder()
        let projects = try context.fetch(FetchDescriptor<MailProject>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        encoder.append("project.count", String(projects.count))
        for project in projects {
            encoder.append("project.id", project.id.uuidString)
            encoder.append("project.name", project.displayName)
            encoder.append("project.normalizedName", project.normalizedName)
            encoder.append("project.revision", String(project.configurationRevision))
            encoder.append(
                "project.boundary",
                project.automaticIntakeStartAt.map(dateFingerprintValue) ?? "<nil>"
            )
            encoder.append(
                "project.accounts",
                try project.accountIDs().map(\.uuidString).sorted().joined(separator: ",")
            )
            for group in project.ruleGroups.sorted(by: persistedGroupOrder) {
                encoder.append("ruleGroup.id", group.id.uuidString)
                encoder.append("ruleGroup.kind", group.kindRawValue)
                encoder.append("ruleGroup.sort", String(group.sortIndex))
                for condition in group.conditions.sorted(by: persistedConditionOrder) {
                    encoder.append("condition.id", condition.id.uuidString)
                    encoder.append("condition.facet", condition.facetRawValue)
                    encoder.append("condition.polarity", condition.polarityRawValue)
                    encoder.append("condition.quantifier", condition.quantifierRawValue)
                    encoder.append("condition.values", condition.valuesJSON)
                    encoder.append(
                        "condition.correspondentRole",
                        condition.correspondentRoleRawValue ?? "<nil>"
                    )
                    encoder.append(
                        "condition.keywordScopes",
                        condition.keywordScopesJSON ?? "<nil>"
                    )
                    encoder.append(
                        "condition.keywordOperator",
                        condition.keywordOperatorRawValue ?? "<nil>"
                    )
                    encoder.append("condition.sort", String(condition.sortIndex))
                }
            }
        }

        let decisions = try context.fetch(FetchDescriptor<MailProjectDecision>())
            .sorted { $0.decisionKey < $1.decisionKey }
        encoder.append("decision.count", String(decisions.count))
        for decision in decisions {
            encoder.append("decision.key", decision.decisionKey)
            encoder.append("decision.id", decision.id.uuidString)
            encoder.append("decision.value", decision.decisionRawValue)
            encoder.append("decision.updatedAt", dateFingerprintValue(decision.updatedAt))
        }

        let memberships = try context.fetch(FetchDescriptor<MailProjectMembership>())
            .sorted { $0.membershipKey < $1.membershipKey }
        encoder.append("membership.count", String(memberships.count))
        for membership in memberships {
            encoder.append("membership.key", membership.membershipKey)
            encoder.append("membership.id", membership.id.uuidString)
            encoder.append("membership.revision", String(membership.configurationRevision))
            encoder.append("membership.source", membership.sourceRawValue)
            encoder.append(
                "membership.group",
                membership.matchingGroupID?.uuidString ?? "<nil>"
            )
            encoder.append("membership.conditions", membership.matchingConditionIDsJSON)
            encoder.append("membership.provenance", membership.provenanceJSON)
            encoder.append("membership.sourceFingerprint", membership.sourceFingerprint)
            encoder.append("membership.evaluatedAt", dateFingerprintValue(membership.evaluatedAt))
        }

        let drafts = try context.fetch(FetchDescriptor<MailProjectConfigurationDraft>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        encoder.append("draft.count", String(drafts.count))
        for draft in drafts {
            encoder.append("draft.id", draft.id.uuidString)
            encoder.append("draft.project", draft.targetProjectID?.uuidString ?? "<nil>")
            encoder.append("draft.revision", String(draft.baseRevision))
            encoder.append("draft.version", String(draft.payloadVersion))
            encoder.append("draft.payload", draft.payloadJSON)
        }

        let accounts = try context.fetch(FetchDescriptor<Account>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        encoder.append("account.count", String(accounts.count))
        for account in accounts { encoder.append("account.id", account.id.uuidString) }

        let correspondents = try context.fetch(FetchDescriptor<Correspondent>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        encoder.append("correspondent.count", String(correspondents.count))
        for correspondent in correspondents {
            encoder.append("correspondent.id", correspondent.id.uuidString)
        }

        let categories = try context.fetch(FetchDescriptor<CustomMailCategory>())
            .sorted { $0.key < $1.key }
        encoder.append("category.count", String(categories.count))
        for category in categories {
            encoder.append("category.key", category.key)
            encoder.append("category.status", category.statusRaw)
        }

        let threads = try context.fetch(FetchDescriptor<MessageThread>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        encoder.append("thread.count", String(threads.count))
        for thread in threads { encoder.append("thread.id", thread.id.uuidString) }

        let messages = try context.fetch(FetchDescriptor<Message>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        encoder.append("message.count", String(messages.count))
        for message in messages {
            encoder.append("message.id", message.id.uuidString)
            encoder.append(
                "message.account",
                (message.accountID ?? message.account?.id)?.uuidString ?? "<nil>"
            )
            encoder.append("message.thread", message.thread?.id.uuidString ?? "<nil>")
            encoder.append("message.subject", message.subject)
            encoder.append("message.from", message.fromAddress)
            encoder.append("message.sentAt", message.sentAt.map(dateFingerprintValue) ?? "<nil>")
            encoder.append(
                "message.receivedAt",
                message.receivedAt.map(dateFingerprintValue) ?? "<nil>"
            )
            encoder.append("message.ingestedAt", dateFingerprintValue(message.ingestedAt))
            encoder.append("message.bodyPath", message.bodyTextPath ?? "<nil>")
            appendFileGeneration(message.bodyTextPath, label: "message.bodyFile", to: &encoder)

            if let analysis = message.analysis {
                encoder.append("analysis.id", analysis.id.uuidString)
                encoder.append("analysis.classification", analysis.mailClassificationJSON ?? "<nil>")
                encoder.append("analysis.custom", analysis.customCategoryKeysJSON ?? "<nil>")
                encoder.append("analysis.dimensions", analysis.dimensionsJSON)
                encoder.append(
                    "analysis.interpretedAt",
                    analysis.interpretedAt.map(dateFingerprintValue) ?? "<nil>"
                )
            } else {
                encoder.append("analysis.id", "<nil>")
            }

            let participants = message.participants.sorted { $0.id.uuidString < $1.id.uuidString }
            encoder.append("participant.count", String(participants.count))
            for link in participants {
                encoder.append("participant.id", link.id.uuidString)
                encoder.append("participant.role", link.role.rawValue)
                encoder.append("participant.address", link.participant?.emailAddress ?? "<nil>")
                encoder.append(
                    "participant.correspondent",
                    link.participant?.correspondent?.id.uuidString ?? "<nil>"
                )
            }

            let attachments = message.attachments.sorted { $0.id.uuidString < $1.id.uuidString }
            encoder.append("attachment.count", String(attachments.count))
            for attachment in attachments {
                encoder.append("attachment.id", attachment.id.uuidString)
                encoder.append("attachment.filename", attachment.filename)
                encoder.append("attachment.path", attachment.extractedTextPath ?? "<nil>")
                encoder.append("attachment.status", attachment.extractionStatus ?? "<nil>")
                appendFileGeneration(
                    attachment.extractedTextPath,
                    label: "attachment.file",
                    to: &encoder
                )
            }
        }
        return encoder.digest
    }

    private func appendFileGeneration(
        _ path: String?,
        label: String,
        to encoder: inout ServiceFingerprintEncoder
    ) {
        guard let path else {
            encoder.append(label, "<nil>")
            return
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value
            let modified = attributes[.modificationDate] as? Date
            encoder.append(
                label,
                [
                    path,
                    size.map(String.init) ?? "<unknown-size>",
                    modified.map(dateFingerprintValue) ?? "<unknown-date>",
                ].joined(separator: "|")
            )
        } catch {
            encoder.append(label, "\(path)|<missing>")
        }
    }

    private func membershipSnapshot(
        _ row: MailProjectMembership
    ) throws -> MailProjectMembershipSnapshot {
        guard let data = row.provenanceJSON.data(using: .utf8),
              let provenance = try? JSONDecoder().decode(
                MailProjectMembershipProvenance.self,
                from: data
              ) else {
            throw ManualProjectConfigurationServiceError.malformedProvenance
        }
        return MailProjectMembershipSnapshot(
            id: row.id,
            projectID: row.projectID,
            messageID: row.messageID,
            configurationRevision: row.configurationRevision,
            source: row.source,
            matchingGroupID: row.matchingGroupID,
            matchingConditionIDs: try row.matchingConditionIDs(),
            provenance: provenance,
            sourceFingerprint: row.sourceFingerprint,
            evaluatedAt: row.evaluatedAt
        )
    }

    // MARK: - Validation and fingerprints

    private func validateAccountScope(
        _ configuration: MailProjectConfigurationSnapshot,
        catalog: MailProjectRuleCatalogSnapshot
    ) throws {
        let valid = Set(catalog.accounts.filter(\.isValid).compactMap {
            UUID(uuidString: $0.stableKey)
        })
        let invalid = configuration.accountIDs.subtracting(valid)
            .sorted { $0.uuidString < $1.uuidString }
        guard invalid.isEmpty else {
            throw ManualProjectConfigurationServiceError.invalidAccountScope(invalid)
        }
    }

    private func validateManualDecisionStructure(
        _ configuration: MailProjectConfigurationSnapshot
    ) throws {
        var keys: Set<String> = []
        var ids: Set<UUID> = []
        for decision in configuration.manualDecisions {
            guard decision.projectID == configuration.projectID,
                  ids.insert(decision.id).inserted else {
                throw ManualProjectConfigurationServiceError.invalidManualDecision(decision.id)
            }
            let key = MailProjectDecision.key(
                projectID: decision.projectID,
                targetKind: decision.targetKind,
                targetID: decision.targetID
            )
            guard keys.insert(key).inserted else {
                throw ManualProjectConfigurationServiceError.duplicateManualDecision(key)
            }
        }
    }

    private func validateManualDecisionTargets(
        _ configuration: MailProjectConfigurationSnapshot,
        messageIDs: Set<UUID>,
        threadIDs: Set<UUID>
    ) throws {
        for decision in configuration.manualDecisions {
            let exists: Bool
            switch decision.targetKind {
            case .message:
                exists = messageIDs.contains(decision.targetID)
            case .thread:
                exists = threadIDs.contains(decision.targetID)
            }
            guard exists else {
                throw ManualProjectConfigurationServiceError.missingManualDecisionTarget(
                    kind: decision.targetKind,
                    id: decision.targetID
                )
            }
        }
    }

    private func selectedValuesByFacet(
        _ configuration: MailProjectConfigurationSnapshot
    ) -> [MailProjectRuleFacet: Set<String>] {
        var result: [MailProjectRuleFacet: Set<String>] = [:]
        result[.account] = Set(configuration.accountIDs.map(\.uuidString))
        for condition in configuration.groups.flatMap(\.conditions) {
            result[condition.facet, default: []].formUnion(condition.values)
        }
        return result
    }

    private func previewFingerprint(
        configuration: MailProjectConfigurationSnapshot,
        catalog: MailProjectRuleCatalogSnapshot,
        messages: [MailProjectMessageSnapshot],
        currentMemberships: [MailProjectMembershipSnapshot],
        currentRuleDetailsByMessageID: [UUID: MailProjectPreviewRuleDetails?],
        candidateRevision: Int,
        draftReviewState: DraftReviewState
    ) throws -> String {
        var encoder = ServiceFingerprintEncoder()
        encoder.append("base", ManualProjectFingerprint.previewFingerprint(
            configuration: configuration,
            catalog: catalog,
            messages: messages
        ))
        encoder.append("candidateRevision", String(candidateRevision))
        for membership in currentMemberships.sorted(by: {
            $0.messageID.uuidString < $1.messageID.uuidString
        }) {
            encoder.append("membership.messageID", membership.messageID.uuidString)
            encoder.append("membership.revision", String(membership.configurationRevision))
            encoder.append("membership.source", membership.source.rawValue)
            encoder.append("membership.group", membership.matchingGroupID?.uuidString ?? "")
            encoder.append(
                "membership.conditions",
                membership.matchingConditionIDs.map(\.uuidString).sorted().joined(separator: ",")
            )
            encoder.append("membership.sourceFingerprint", membership.sourceFingerprint)
            encoder.append("membership.provenance", try encodeProvenance(membership.provenance))
            encoder.append(
                "membership.ruleDetails",
                currentRuleDetailsByMessageID[membership.messageID]
                    .flatMap { $0 }
                    .map(encodeRuleDetails) ?? "<nil>"
            )
        }
        encoder.append("draftReview.kind", draftReviewState.kind)
        if let durableState = draftReviewState.durableState {
            encoder.append("draftReview.id", durableState.id.uuidString)
            encoder.append("draftReview.fingerprint", durableState.fingerprint)
        }
        return encoder.digest
    }

    private func broadRuleWarning(
        configuration: MailProjectConfigurationSnapshot,
        exactMatchCount: Int,
        eligibleMessageCount: Int
    ) -> MailProjectBroadRuleWarning? {
        var reasons: [MailProjectBroadRuleReason] = []
        let sharedGroup = configuration.groups.first { $0.kind == .sharedCriteria }
        let sharedPositiveCount = sharedGroup?.conditions.count {
            $0.polarity == .include
        } ?? 0
        let matchGroups = configuration.groups.filter { $0.kind == .match }
        let automaticPaths: [(conditionCount: Int, positiveCount: Int)]
        if matchGroups.isEmpty == false {
            automaticPaths = matchGroups.map { group in
                (
                    conditionCount: (sharedGroup?.conditions.count ?? 0) + group.conditions.count,
                    positiveCount: sharedPositiveCount
                        + group.conditions.count { $0.polarity == .include }
                )
            }
        } else {
            automaticPaths = []
        }
        for path in automaticPaths {
            if path.conditionCount > 0, path.positiveCount == 0 {
                reasons.append(.exclusionOnlyGroup)
            } else if path.positiveCount == 1 {
                reasons.append(.singlePositiveCondition)
            }
        }
        if eligibleMessageCount > 0, exactMatchCount == eligibleMessageCount,
           automaticPaths.isEmpty == false {
            reasons.append(.matchesAllEligibleMessages)
        }
        guard reasons.isEmpty == false else { return nil }
        return MailProjectBroadRuleWarning(
            reasons: reasons,
            exactMatchCount: exactMatchCount,
            eligibleMessageCount: eligibleMessageCount
        )
    }

    private func isAutomaticallyEligible(
        _ message: MailProjectMessageSnapshot,
        for configuration: MailProjectConfigurationSnapshot
    ) -> Bool {
        if configuration.accountIDs.isEmpty == false {
            guard let accountID = message.accountID,
                  configuration.accountIDs.contains(accountID) else {
                return false
            }
        }
        if let boundary = configuration.automaticIntakeStartAt,
           message.messageDate < boundary {
            return false
        }
        return true
    }

    private func encodeProvenance(
        _ provenance: MailProjectMembershipProvenance
    ) throws -> String {
        let canonical = CanonicalMembershipProvenance(
            rule: provenance.rule.map {
                CanonicalRuleProvenance(
                    matchingGroupID: $0.matchingGroupID,
                    matchingConditionIDs: $0.matchingConditionIDs.sorted {
                        $0.uuidString < $1.uuidString
                    }
                )
            },
            decisionID: provenance.decisionID,
            decisionTargetKind: provenance.decisionTargetKind,
            isExceptionToAutomaticRules: provenance.isExceptionToAutomaticRules
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(canonical), as: UTF8.self)
    }

    private func encodeRuleDetails(
        _ details: MailProjectPreviewRuleDetails
    ) -> String {
        ManualProjectPreviewRuleDetailsFingerprint.digest(details)
    }

    private func ruleDetails(
        for provenance: MailProjectMembershipProvenance,
        configuration: MailProjectConfigurationSnapshot,
        side: MailProjectPreviewRuleConfiguration
    ) -> MailProjectPreviewRuleDetails? {
        guard let rule = provenance.rule else { return nil }
        let matchingConditionIDs = rule.matchingConditionIDs
        let sharedGroups = configuration.groups
            .filter { $0.kind == .sharedCriteria }
            .sorted(by: snapshotGroupOrder)
        let sharedKind: MailProjectPreviewRuleSharedKind
        let sharedConditions: [MailProjectRuleConditionSnapshot]
        if sharedGroups.isEmpty {
            sharedKind = .none
            sharedConditions = []
        } else if let shared = sharedGroups.first {
            let matched = shared.conditions
                .filter { matchingConditionIDs.contains($0.id) }
                .sorted(by: snapshotConditionOrder)
            if matched.count == shared.conditions.count {
                sharedKind = .matched
                sharedConditions = matched
            } else {
                sharedKind = .unavailable
                sharedConditions = []
            }
        } else {
            sharedKind = .unavailable
            sharedConditions = []
        }

        let matchingGroup = configuration.groups.first {
            $0.id == rule.matchingGroupID && $0.kind == .match
        }
        let pathKind: MailProjectPreviewRulePathKind
        let pathConditions: [MailProjectRuleConditionSnapshot]
        if let matchingGroup {
            let matched = matchingGroup.conditions
                .filter { matchingConditionIDs.contains($0.id) }
                .sorted(by: snapshotConditionOrder)
            if matched.count == matchingGroup.conditions.count {
                pathKind = .matchedGroup
                pathConditions = matched
            } else {
                pathKind = .unavailable
                pathConditions = []
            }
        } else {
            let hasMatchGroups = configuration.groups.contains { $0.kind == .match }
            let accountWideSentinel = sharedGroups.first?.id
                ?? (configuration.groups.contains { $0.kind == .projectWideExclusion }
                    ? configuration.projectID
                    : nil)
            if hasMatchGroups == false,
               accountWideSentinel == rule.matchingGroupID {
                pathKind = .accountWide
            } else {
                pathKind = .unavailable
            }
            pathConditions = []
        }

        return MailProjectPreviewRuleDetails(
            configuration: side,
            sharedKind: sharedKind,
            sharedConditions: sharedConditions,
            pathKind: pathKind,
            pathConditions: pathConditions
        )
    }

    // MARK: - Small helpers

    private func freshContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func replacingBoundary(
        in configuration: MailProjectConfigurationSnapshot,
        with boundary: Date?
    ) -> MailProjectConfigurationSnapshot {
        MailProjectConfigurationSnapshot(
            projectID: configuration.projectID,
            existingProjectID: configuration.existingProjectID,
            displayName: configuration.displayName,
            accountIDs: configuration.accountIDs,
            automaticIntakeStartAt: boundary,
            baseConfigurationRevision: configuration.baseConfigurationRevision,
            groups: configuration.groups,
            manualDecisions: configuration.manualDecisions
        )
    }

    private func boundary(_ proposed: Date?, expandsBackwardFrom live: Date?) -> Bool {
        guard let live else { return false }
        guard let proposed else { return true }
        return proposed < live
    }

    private func snapshotGroupOrder(
        _ lhs: MailProjectRuleGroupSnapshot,
        _ rhs: MailProjectRuleGroupSnapshot
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func snapshotConditionOrder(
        _ lhs: MailProjectRuleConditionSnapshot,
        _ rhs: MailProjectRuleConditionSnapshot
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func snapshotDecisionOrder(
        _ lhs: MailProjectDecisionSnapshot,
        _ rhs: MailProjectDecisionSnapshot
    ) -> Bool {
        if lhs.targetKind.rawValue != rhs.targetKind.rawValue {
            return lhs.targetKind.rawValue < rhs.targetKind.rawValue
        }
        if lhs.targetID != rhs.targetID { return lhs.targetID.uuidString < rhs.targetID.uuidString }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func persistedGroupOrder(
        _ lhs: MailProjectRuleGroup,
        _ rhs: MailProjectRuleGroup
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func persistedConditionOrder(
        _ lhs: MailProjectRuleCondition,
        _ rhs: MailProjectRuleCondition
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func persistedDecisionOrder(
        _ lhs: MailProjectDecision,
        _ rhs: MailProjectDecision
    ) -> Bool {
        if lhs.targetKindRawValue != rhs.targetKindRawValue {
            return lhs.targetKindRawValue < rhs.targetKindRawValue
        }
        if lhs.targetID != rhs.targetID { return lhs.targetID.uuidString < rhs.targetID.uuidString }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private enum BoundaryPolicy {
    case ordinary
    case includeEarlier

    var draftParticipationPolicy: DraftParticipationPolicy {
        switch self {
        case .ordinary: .ordinaryExact
        case .includeEarlier: .ignore
        }
    }
}

private enum DraftParticipationPolicy {
    case ordinaryExact
    case ignore
}

private struct PreparedConfiguration {
    let configuration: MailProjectConfigurationSnapshot
    let preview: MailProjectPreview
    let evaluated: [MailProjectEvaluatedMessage]
    let affectedMessageIDs: Set<UUID>
    let draftReviewState: DraftReviewState
    let sourceFreshnessStamp: String
}

private struct DurableDraftState: Sendable, Equatable {
    let id: UUID
    let fingerprint: String
}

private enum DraftReviewState: Sendable, Equatable {
    case none
    case matching(DurableDraftState)
    case conflicting(DurableDraftState)

    var isConflict: Bool {
        if case .conflicting = self { return true }
        return false
    }

    var kind: String {
        switch self {
        case .none: "none"
        case .matching: "matching"
        case .conflicting: "conflicting"
        }
    }

    var durableState: DurableDraftState? {
        switch self {
        case .none: nil
        case let .matching(state), let .conflicting(state): state
        }
    }
}

private struct ExistingDecisionCreation {
    let key: String
    let createdAt: Date
}

private struct CommitReceipt {
    let projectID: UUID
    let configurationRevision: Int
    let affectedMessageIDs: Set<UUID>
}

private enum FinalizationResult {
    case reviewRequired(MailProjectPreview)
    case idempotent(projectID: UUID, configurationRevision: Int)
    case committed(CommitReceipt)
    case stale
}

private struct ProjectionReplacement {
    let messageID: UUID
    let source: MailProjectMembershipSource
    let provenance: MailProjectMembershipProvenance
    let provenanceJSON: String
    let sourceFingerprint: String
    let evaluatedAt: Date
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

enum ManualProjectPreviewRuleDetailsFingerprint {
    static func digest(_ details: MailProjectPreviewRuleDetails) -> String {
        var encoder = ServiceFingerprintEncoder()
        encoder.append("configuration", details.configuration.rawValue)
        encoder.append("shared.kind", details.sharedKind.rawValue)
        append(details.sharedConditions, prefix: "shared", to: &encoder)
        encoder.append("path.kind", details.pathKind.rawValue)
        append(details.pathConditions, prefix: "path", to: &encoder)
        return encoder.digest
    }

    private static func append(
        _ conditions: [MailProjectRuleConditionSnapshot],
        prefix: String,
        to encoder: inout ServiceFingerprintEncoder
    ) {
        let canonicalConditions = conditions.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        encoder.append("\(prefix).conditionCount", String(canonicalConditions.count))
        for condition in canonicalConditions {
            encoder.append("\(prefix).condition.id", condition.id.uuidString)
            encoder.append("\(prefix).condition.facet", condition.facet.rawValue)
            encoder.append("\(prefix).condition.polarity", condition.polarity.rawValue)
            encoder.append("\(prefix).condition.quantifier", condition.quantifier.rawValue)
            let values = Set(condition.values).sorted()
            encoder.append("\(prefix).condition.valueCount", String(values.count))
            for value in values {
                encoder.append("\(prefix).condition.value", value)
            }
            encoder.append(
                "\(prefix).condition.correspondentRole",
                condition.correspondentRole?.rawValue ?? "<nil>"
            )
            let keywordScopes = condition.keywordScopes.map(\.rawValue).sorted()
            encoder.append(
                "\(prefix).condition.keywordScopeCount",
                String(keywordScopes.count)
            )
            for keywordScope in keywordScopes {
                encoder.append("\(prefix).condition.keywordScope", keywordScope)
            }
            encoder.append(
                "\(prefix).condition.keywordOperator",
                condition.keywordOperator?.rawValue ?? "<nil>"
            )
            encoder.append("\(prefix).condition.sortIndex", String(condition.sortIndex))
        }
    }
}

private struct ServiceFingerprintEncoder {
    private var data = Data()

    mutating func append(_ key: String, _ value: String) {
        appendLengthPrefixed(Data(key.utf8))
        appendLengthPrefixed(Data(value.utf8))
    }

    var digest: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func appendLengthPrefixed(_ value: Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}
