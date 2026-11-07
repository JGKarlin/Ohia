import Foundation
import OhiaCore
import SwiftData
import Synchronization

struct ManualProjectReconciliationBatch: Sendable, Equatable {
    var messageIDs: Set<UUID> = []
    var changedFacets: Set<MailProjectRuleFacet> = []
    var projectIDs: Set<UUID> = []
    var rebuildAll = false

    var isEmpty: Bool {
        messageIDs.isEmpty && projectIDs.isEmpty && rebuildAll == false
    }

    mutating func formUnion(_ other: Self) {
        messageIDs.formUnion(other.messageIDs)
        changedFacets.formUnion(other.changedFacets)
        projectIDs.formUnion(other.projectIDs)
        rebuildAll = rebuildAll || other.rebuildAll
    }
}

enum ManualProjectMembershipCoordinatorCheckpoint: Sendable, Equatable {
    case beforeBatch(ManualProjectReconciliationBatch)
    case beforeMessageSnapshot(UUID)
    case afterSnapshot(projectID: UUID, revision: Int)
}

public actor ManualProjectMembershipCoordinator {
    private let container: ModelContainer
    private let textReader: any ProjectTextFileReading
    private let notificationCenter: NotificationCenter
    private let now: @Sendable () -> Date
    private let suspension: @Sendable (ManualProjectMembershipCoordinatorCheckpoint) async throws -> Void
    private let beforeRepositorySave: @MainActor @Sendable () throws -> Void
    private let beforeHealthSave: @MainActor @Sendable () throws -> Void

    private var pending = ManualProjectReconciliationBatch()
    private var failedScopes: [UUID: ProjectWorkScope] = [:]
    private var worker: Task<Void, Never>?
    private var activeCancellation: ManualProjectCancellationToken?
    private var stopped = false

    public init(container: ModelContainer, textReader: any ProjectTextFileReading) {
        self.init(
            container: container,
            textReader: textReader,
            notificationCenter: .default,
            now: { .now },
            suspension: { _ in },
            beforeRepositorySave: {},
            beforeHealthSave: {}
        )
    }

    init(
        container: ModelContainer,
        textReader: any ProjectTextFileReading,
        notificationCenter: NotificationCenter = .default,
        now: @escaping @Sendable () -> Date = { .now },
        suspension: @escaping @Sendable (ManualProjectMembershipCoordinatorCheckpoint) async throws -> Void = { _ in },
        beforeRepositorySave: @escaping @MainActor @Sendable () throws -> Void = {},
        beforeHealthSave: @escaping @MainActor @Sendable () throws -> Void = {}
    ) {
        self.container = container
        self.textReader = textReader
        self.notificationCenter = notificationCenter
        self.now = now
        self.suspension = suspension
        self.beforeRepositorySave = beforeRepositorySave
        self.beforeHealthSave = beforeHealthSave
    }

    public func reconcile(
        messageIDs: Set<UUID>,
        changedFacets: Set<MailProjectRuleFacet>
    ) async {
        await enqueue(ManualProjectReconciliationBatch(
            messageIDs: messageIDs,
            changedFacets: changedFacets
        ))
    }

    public func reconcile(projectIDs: Set<UUID>) async {
        await enqueue(ManualProjectReconciliationBatch(projectIDs: projectIDs))
    }

    public func rebuildAll() async {
        await enqueue(ManualProjectReconciliationBatch(rebuildAll: true))
    }

    public func cancel() async {
        stopped = true
        pending = ManualProjectReconciliationBatch()
        activeCancellation?.cancel()
        let owned = worker
        owned?.cancel()
        await owned?.value
        worker = nil
        activeCancellation = nil
    }

    private func enqueue(_ batch: ManualProjectReconciliationBatch) async {
        guard stopped == false, batch.isEmpty == false else { return }
        pending.formUnion(batch)
        if worker == nil {
            let token = ManualProjectCancellationToken()
            activeCancellation = token
            worker = Task { await self.drain(cancellation: token) }
        }
        let owned = worker
        await owned?.value
    }

    private func drain(cancellation: ManualProjectCancellationToken) async {
        await Task.yield()
        while stopped == false, pending.isEmpty == false {
            do {
                try cancellation.check()
                try Task.checkCancellation()
                let batch = pending
                pending = ManualProjectReconciliationBatch()
                try await suspension(.beforeBatch(batch))
                try cancellation.check()
                try await process(batch, cancellation: cancellation)
            } catch is CancellationError {
                break
            } catch {
                // Project-attributable failures are persisted and retained by process.
            }
        }
        if activeCancellation === cancellation {
            activeCancellation = nil
        }
        worker = nil
    }

    private func process(
        _ batch: ManualProjectReconciliationBatch,
        cancellation: ManualProjectCancellationToken
    ) async throws {
        let routing = try await detached(cancellation: cancellation) {
            try Self.routingSnapshot(container: self.container, cancellation: cancellation)
        }
        try cancellation.check()

        let threadIDs = try await detached(cancellation: cancellation) {
            try Self.messageThreadIDs(
                batch.messageIDs,
                container: self.container,
                cancellation: cancellation
            )
        }
        let selectedProjectIDs: Set<UUID>
        if batch.rebuildAll {
            selectedProjectIDs = routing.index.projectIDs.union(routing.unindexableProjectIDs)
        } else {
            var selected = batch.projectIDs.union(routing.index.affectedProjectIDs(
                messageIDs: batch.messageIDs,
                threadIDs: threadIDs,
                changedFacets: batch.changedFacets
            ))
            if batch.messageIDs.isEmpty == false || batch.changedFacets.isEmpty == false {
                selected.formUnion(routing.unindexableProjectIDs)
            }
            selectedProjectIDs = selected
        }

        for projectID in selectedProjectIDs.sorted(by: Self.uuidOrder) {
            try cancellation.check()
            guard stopped == false else { throw CancellationError() }
            let incoming: ProjectWorkScope = batch.rebuildAll || batch.projectIDs.contains(projectID)
                ? .full
                : .messages(batch.messageIDs, batch.changedFacets)
            let scope = incoming.union(failedScopes[projectID])
            do {
                guard let input = routing.inputs[projectID] else {
                    throw routing.errors[projectID] ?? CoordinatorReadError.missingConfiguration(projectID)
                }
                let existing = try await detached(cancellation: cancellation) {
                    try Self.existingMemberships(
                        projectID: projectID,
                        scope: scope,
                        container: self.container,
                        cancellation: cancellation
                    )
                }
                let messageIDs = try await messageIDs(
                    for: scope,
                    cancellation: cancellation
                )
                var snapshots: [MailProjectMessageSnapshot] = []
                snapshots.reserveCapacity(messageIDs.count)
                var sourceStateFingerprints: [UUID: String] = [:]
                sourceStateFingerprints.reserveCapacity(messageIDs.count)
                for messageID in messageIDs.sorted(by: Self.uuidOrder) {
                    try cancellation.check()
                    try await suspension(.beforeMessageSnapshot(messageID))
                    try cancellation.check()
                    let generation = try await detached(cancellation: cancellation, operation: {
                        try Self.stableMessageSnapshotGeneration(
                            messageID: messageID,
                            container: self.container,
                            textReader: self.textReader,
                            cancellation: cancellation
                        )
                    })
                    sourceStateFingerprints[messageID] = generation.sourceStateFingerprint
                    if let snapshot = generation.snapshot {
                        snapshots.append(snapshot)
                    }
                }
                let timestamp = now()
                let messageSnapshots = snapshots
                let messageSourceStateFingerprints = sourceStateFingerprints
                let prepared = try await detached(cancellation: cancellation) {
                    try Self.evaluate(
                        input: input,
                        scope: scope,
                        messages: messageSnapshots,
                        existing: existing,
                        evaluatedAt: timestamp,
                        sourceStateFingerprints: messageSourceStateFingerprints,
                        cancellation: cancellation
                    )
                }
                try await suspension(.afterSnapshot(projectID: projectID, revision: prepared.revision))
                try cancellation.check()
                do {
                    try await persist(prepared, cancellation: cancellation)
                    failedScopes.removeValue(forKey: projectID)
                } catch ManualProjectMembershipRepositoryError.staleRevision,
                        ManualProjectMembershipRepositoryError.staleMessageSource {
                    pending.projectIDs.insert(projectID)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedScopes[projectID] = scope.union(failedScopes[projectID])
                do {
                    try await persistFailureIfCurrent(
                        projectID: projectID,
                        expectedRevision: routing.revisions[projectID],
                        error: error,
                        cancellation: cancellation
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A failed health write is retained, but cannot stop later projects.
                }
            }
        }
    }

    private func messageIDs(
        for scope: ProjectWorkScope,
        cancellation: ManualProjectCancellationToken
    ) async throws -> Set<UUID> {
        switch scope {
        case .full:
            return try await detached(cancellation: cancellation) {
                try Self.allMessageIDs(container: self.container, cancellation: cancellation)
            }
        case let .messages(messageIDs, _):
            return messageIDs
        }
    }

    private func persist(
        _ prepared: PreparedReconciliation,
        cancellation: ManualProjectCancellationToken
    ) async throws {
        try cancellation.check()
        try await MainActor.run {
            try cancellation.check()
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let repository = ManualProjectMembershipRepository(
                modelContext: context,
                notificationCenter: notificationCenter,
                now: now,
                beforeSave: beforeRepositorySave
            )
            try repository.reconcileAtomically(
                projectID: prepared.projectID,
                evaluated: prepared.evaluated,
                sourceStateFingerprints: prepared.sourceStateFingerprints,
                revision: prepared.revision,
                scope: prepared.scope.repositoryScope,
                health: prepared.validation.isValid ? .healthy : .needsAttention,
                lastMembershipError: prepared.validation.isValid
                    ? nil
                    : Self.validationError(prepared.validation),
                cancellationCheck: { try cancellation.check() }
            )
        }
    }

    private func persistFailureIfCurrent(
        projectID: UUID,
        expectedRevision: Int?,
        error: any Error,
        cancellation: ManualProjectCancellationToken
    ) async throws {
        guard let expectedRevision else { return }
        try await MainActor.run {
            try cancellation.check()
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let repository = ManualProjectMembershipRepository(
                modelContext: context,
                notificationCenter: notificationCenter,
                now: now,
                beforeSave: beforeHealthSave
            )
            try repository.updateMembershipHealthAtomically(
                projectID: projectID,
                revision: expectedRevision,
                health: .membershipUpdatePending,
                lastMembershipError: String(reflecting: error),
                cancellationCheck: { try cancellation.check() }
            )
        }
    }

    private func detached<Value: Sendable>(
        cancellation: ManualProjectCancellationToken,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached {
            try cancellation.check()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
    }

    private static func routingSnapshot(
        container: ModelContainer,
        cancellation: ManualProjectCancellationToken
    ) throws -> RoutingSnapshot {
        let context = freshContext(container)
        let projects = try context.fetch(FetchDescriptor<MailProject>())
            .sorted { uuidOrder($0.id, $1.id) }
        let selectedValues = try selectedValuesByFacet(projects)
        let catalog = try validityCatalog(
            context: context,
            selectedValuesByFacet: selectedValues
        )
        var configurations: [MailProjectConfigurationSnapshot] = []
        var inputs: [UUID: ProjectInput] = [:]
        var revisions: [UUID: Int] = [:]
        var errors: [UUID: CoordinatorReadError] = [:]
        var unindexable: Set<UUID> = []
        for project in projects {
            try cancellation.check()
            revisions[project.id] = project.configurationRevision
            do {
                let configuration = try configurationSnapshot(project, in: context)
                configurations.append(configuration)
                var validation = ManualProjectConfigurationValidator.validate(
                    configuration: configuration,
                    catalog: catalog
                )
                validation = validationIncludingAccountScope(
                    validation,
                    configuration: configuration,
                    catalog: catalog
                )
                let dependencies = ManualProjectDependencyIndex.dependencySet(
                    for: configuration
                )
                inputs[project.id] = ProjectInput(
                    configuration: configuration,
                    validation: validation,
                    dependencies: dependencies,
                    revision: project.configurationRevision
                )
            } catch {
                unindexable.insert(project.id)
                errors[project.id] = .configuration(project.id, String(reflecting: error))
            }
        }
        return RoutingSnapshot(
            index: ManualProjectDependencyIndex(configurations: configurations),
            inputs: inputs,
            revisions: revisions,
            errors: errors,
            unindexableProjectIDs: unindexable
        )
    }

    private static func allMessageIDs(
        container: ModelContainer,
        cancellation: ManualProjectCancellationToken
    ) throws -> Set<UUID> {
        let context = freshContext(container)
        var result: Set<UUID> = []
        for message in try context.fetch(FetchDescriptor<Message>()) {
            try cancellation.check()
            result.insert(message.id)
        }
        return result
    }

    private static func messageThreadIDs(
        _ messageIDs: Set<UUID>,
        container: ModelContainer,
        cancellation: ManualProjectCancellationToken
    ) throws -> Set<UUID> {
        guard messageIDs.isEmpty == false else { return [] }
        let context = freshContext(container)
        var result: Set<UUID> = []
        for messageID in messageIDs.sorted(by: uuidOrder) {
            try cancellation.check()
            let id = messageID
            let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
            if let threadID = try context.fetch(descriptor).first?.thread?.id {
                result.insert(threadID)
            }
        }
        return result
    }

    private static func stableMessageSnapshotGeneration(
        messageID: UUID,
        container: ModelContainer,
        textReader: any ProjectTextFileReading,
        cancellation: ManualProjectCancellationToken
    ) throws -> MessageSnapshotGeneration {
        for _ in 0..<2 {
            try cancellation.check()
            let context = freshContext(container)
            let id = messageID
            let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
            let message = try context.fetch(descriptor).first
            let before = ManualProjectFingerprint.messageSourceStateFingerprint(message)
            let snapshot = try message.map {
                try ManualProjectMessageSnapshotBuilder(textReader: textReader).snapshot(for: $0)
            }
            try cancellation.check()
            let verificationContext = freshContext(container)
            let current = try verificationContext.fetch(descriptor).first
            let after = ManualProjectFingerprint.messageSourceStateFingerprint(current)
            if before == after {
                return MessageSnapshotGeneration(
                    snapshot: snapshot,
                    sourceStateFingerprint: after
                )
            }
        }
        throw CoordinatorReadError.unstableMessageSource(messageID)
    }

    private static func existingMemberships(
        projectID: UUID,
        scope: ProjectWorkScope,
        container: ModelContainer,
        cancellation: ManualProjectCancellationToken
    ) throws -> [UUID: MailProjectMembershipSnapshot] {
        let context = freshContext(container)
        let rows: [MailProjectMembership]
        switch scope {
        case .full:
            let id = projectID
            rows = try context.fetch(FetchDescriptor<MailProjectMembership>(
                predicate: #Predicate { $0.projectID == id }
            ))
        case let .messages(messageIDs, _):
            rows = try messageIDs.sorted(by: uuidOrder).compactMap { messageID in
                try cancellation.check()
                let key = MailProjectMembership.key(
                    projectID: projectID,
                    messageID: messageID
                )
                return try context.fetch(FetchDescriptor<MailProjectMembership>(
                    predicate: #Predicate { $0.membershipKey == key }
                )).first
            }
        }
        var result: [UUID: MailProjectMembershipSnapshot] = [:]
        for row in rows {
            try cancellation.check()
            guard let provenance = try? JSONDecoder().decode(
                MailProjectMembershipProvenance.self,
                from: Data(row.provenanceJSON.utf8)
            ), let conditionIDs = try? row.matchingConditionIDs() else {
                continue
            }
            result[row.messageID] = MailProjectMembershipSnapshot(
                id: row.id,
                projectID: row.projectID,
                messageID: row.messageID,
                configurationRevision: row.configurationRevision,
                source: row.source,
                matchingGroupID: row.matchingGroupID,
                matchingConditionIDs: conditionIDs,
                provenance: provenance,
                sourceFingerprint: row.sourceFingerprint,
                evaluatedAt: row.evaluatedAt
            )
        }
        return result
    }

    private static func evaluate(
        input: ProjectInput,
        scope: ProjectWorkScope,
        messages: [MailProjectMessageSnapshot],
        existing: [UUID: MailProjectMembershipSnapshot],
        evaluatedAt: Date,
        sourceStateFingerprints: [UUID: String],
        cancellation: ManualProjectCancellationToken
    ) throws -> PreparedReconciliation {
        var evaluated: [MailProjectEvaluatedMessage] = []
        for snapshot in messages.sorted(by: { uuidOrder($0.id, $1.id) }) {
            try cancellation.check()
            let regenerating = input.dependencies.facets.contains {
                snapshot.readinessByFacet[$0] == .regeneratingWithCommittedValue
            }
            let automatic: MailProjectAutomaticEvaluation
            if regenerating {
                automatic = retainedAutomaticEvaluation(
                    from: existing[snapshot.id],
                    validation: input.validation,
                    pendingFacets: input.dependencies.facets
                )
            } else {
                automatic = ManualProjectRuleEvaluator.evaluate(
                    configuration: input.configuration,
                    message: snapshot,
                    validationReport: input.validation
                )
            }
            let finalDecision = ManualProjectMembershipDecision.resolve(
                messageID: snapshot.id,
                threadID: snapshot.threadID,
                decisions: input.configuration.manualDecisions,
                automatic: automatic
            )
            let fingerprint = regenerating
                ? existing[snapshot.id]?.sourceFingerprint
                    ?? ManualProjectFingerprint.messageSourceFingerprint(
                        snapshot,
                        dependencySet: input.dependencies
                    )
                : ManualProjectFingerprint.messageSourceFingerprint(
                    snapshot,
                    dependencySet: input.dependencies
                )
            if let prior = existing[snapshot.id],
               projection(finalDecision, sourceFingerprint: fingerprint, matches: prior) {
                evaluated.append(evaluatedMessage(preserving: prior))
            } else {
                evaluated.append(MailProjectEvaluatedMessage(
                    messageID: snapshot.id,
                    finalDecision: finalDecision,
                    sourceFingerprint: fingerprint,
                    evaluatedAt: evaluatedAt
                ))
            }
        }
        return PreparedReconciliation(
            projectID: input.configuration.projectID,
            revision: input.revision,
            validation: input.validation,
            evaluated: evaluated,
            sourceStateFingerprints: sourceStateFingerprints,
            scope: scope
        )
    }

    private static func configurationSnapshot(
        _ project: MailProject,
        in context: ModelContext
    ) throws -> MailProjectConfigurationSnapshot {
        let groups = try project.ruleGroups.sorted(by: groupOrder).map { group in
            MailProjectRuleGroupSnapshot(
                id: group.id,
                kind: group.kind,
                sortIndex: group.sortIndex,
                conditions: try group.conditions.sorted(by: conditionOrder).map { condition in
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
            .filter { $0.projectID == project.id }
            .sorted(by: decisionOrder)
            .map {
                MailProjectDecisionSnapshot(
                    id: $0.id,
                    projectID: $0.projectID,
                    targetKind: $0.targetKind,
                    targetID: $0.targetID,
                    decision: $0.decision,
                    updatedAt: $0.updatedAt
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

    private static func selectedValuesByFacet(
        _ projects: [MailProject]
    ) throws -> [MailProjectRuleFacet: Set<String>] {
        var result: [MailProjectRuleFacet: Set<String>] = [:]
        for project in projects {
            if let accountIDs = try? project.accountIDs() {
                result[.account, default: []].formUnion(accountIDs.map(\.uuidString))
            }
            for group in project.ruleGroups {
                for condition in group.conditions {
                    if let values = try? condition.values() {
                        result[condition.facet, default: []].formUnion(values)
                    }
                }
            }
        }
        return result
    }

    private static func validityCatalog(
        context: ModelContext,
        selectedValuesByFacet: [MailProjectRuleFacet: Set<String>]
    ) throws -> MailProjectRuleCatalogSnapshot {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let correspondents = try context.fetch(FetchDescriptor<Correspondent>())
        let participants = try context.fetch(FetchDescriptor<Participant>())
        let mailingLists = try context.fetch(FetchDescriptor<MailingList>())
        let categories = try context.fetch(FetchDescriptor<CustomMailCategory>()).filter {
            $0.statusRaw == CustomMailCategoryStatus.collecting.rawValue
                || $0.statusRaw == CustomMailCategoryStatus.active.rawValue
        }
        let accountIDs = Set(accounts.map { $0.id.uuidString })
        var accountValues = accounts.map {
            MailProjectCatalogValue(
                stableKey: $0.id.uuidString,
                displayName: $0.displayName,
                currentMatchCount: 0,
                isValid: true
            )
        }
        for key in selectedValuesByFacet[.account, default: []] where accountIDs.contains(key) == false {
            accountValues.append(MailProjectCatalogValue(
                stableKey: key,
                displayName: key,
                currentMatchCount: 0,
                isValid: false
            ))
        }
        var correspondentValues = correspondents.map {
            MailProjectCorrespondentCatalogValue(
                id: $0.id,
                canonicalID: $0.id,
                displayName: $0.primaryName,
                resolvedAddresses: [],
                currentMatchCount: 0
            )
        }
        correspondentValues.append(contentsOf: participants.compactMap { participant in
            guard participant.correspondent == nil else { return nil }
            let address = participant.emailAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let name = participant.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = if let name, name.isEmpty == false {
                name
            } else if address.isEmpty == false {
                address
            } else {
                participant.id.uuidString
            }
            return MailProjectCorrespondentCatalogValue(
                id: participant.id,
                canonicalID: participant.id,
                displayName: displayName,
                resolvedAddresses: address.isEmpty ? [] : [address],
                currentMatchCount: 0
            )
        })
        let selectedCorrespondentIDs = selectedValuesByFacet[.correspondent, default: []]
        correspondentValues.append(contentsOf: participants.compactMap { participant in
            guard let correspondentID = participant.correspondent?.id,
                  selectedCorrespondentIDs.contains(participant.id.uuidString) else {
                return nil
            }
            let address = participant.emailAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let name = participant.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = if let name, name.isEmpty == false {
                name
            } else if address.isEmpty == false {
                address
            } else {
                participant.id.uuidString
            }
            return MailProjectCorrespondentCatalogValue(
                id: participant.id,
                canonicalID: correspondentID,
                displayName: displayName,
                resolvedAddresses: address.isEmpty ? [] : [address],
                currentMatchCount: 0
            )
        })
        var valuesByFacet: [MailProjectRuleFacet: [MailProjectCatalogValue]] = [:]
        valuesByFacet[.fixedCategory] = MailPurpose.allCases.map {
            MailProjectCatalogValue(
                stableKey: $0.rawValue,
                displayName: $0.displayLabel,
                currentMatchCount: 0,
                isValid: true
            )
        }
        let categoryKeys = Set(categories.map(\.key))
        var categoryValues = categories.map {
            MailProjectCatalogValue(
                stableKey: $0.key,
                displayName: $0.displayName,
                currentMatchCount: 0,
                isValid: true
            )
        }
        for key in selectedValuesByFacet[.customCategory, default: []]
            where categoryKeys.contains(key) == false {
            categoryValues.append(MailProjectCatalogValue(
                stableKey: key,
                displayName: key,
                currentMatchCount: 0,
                isValid: false
            ))
        }
        valuesByFacet[.customCategory] = categoryValues
        let mailingListKeys = Set(mailingLists.map {
            MailProjectMailingListValue.stableKey(
                accountID: $0.accountID,
                listID: $0.listId
            )
        })
        var mailingListValues = mailingLists.map {
            MailProjectCatalogValue(
                stableKey: MailProjectMailingListValue.stableKey(
                    accountID: $0.accountID,
                    listID: $0.listId
                ),
                displayName: $0.displayName,
                detail: $0.listAddress ?? $0.listId,
                currentMatchCount: 0,
                isValid: true
            )
        }
        for key in selectedValuesByFacet[.mailingList, default: []]
            where mailingListKeys.contains(key) == false {
            mailingListValues.append(MailProjectCatalogValue(
                stableKey: key,
                displayName: key,
                detail: key,
                currentMatchCount: 0,
                isValid: false
            ))
        }
        valuesByFacet[.mailingList] = mailingListValues
        for facet in metadataFacets {
            valuesByFacet[facet] = selectedValuesByFacet[facet, default: []].sorted().map {
                MailProjectCatalogValue(
                    stableKey: $0,
                    displayName: $0,
                    currentMatchCount: 0,
                    isValid: true
                )
            }
        }
        return MailProjectRuleCatalogSnapshot(
            accounts: accountValues,
            correspondents: correspondentValues,
            valuesByFacet: valuesByFacet,
            validityRevision: [
                accountIDs.sorted().joined(separator: ","),
                (correspondents.map(\.id) + participants.map(\.id))
                    .map(\.uuidString)
                    .sorted()
                    .joined(separator: ","),
                categoryKeys.sorted().joined(separator: ","),
                mailingListKeys.sorted().joined(separator: ","),
            ].joined(separator: "|")
        )
    }

    private static func validationIncludingAccountScope(
        _ report: MailProjectValidationReport,
        configuration: MailProjectConfigurationSnapshot,
        catalog: MailProjectRuleCatalogSnapshot
    ) -> MailProjectValidationReport {
        let validAccounts = Set(catalog.accounts.filter(\.isValid).compactMap {
            UUID(uuidString: $0.stableKey)
        })
        let missing = configuration.accountIDs.subtracting(validAccounts)
        guard missing.isEmpty == false else { return report }
        let syntheticGroupID = configuration.groups.first?.id ?? configuration.projectID
        let extra = missing.sorted(by: uuidOrder).map {
            MailProjectValidationIssue(
                code: .invalidCatalogValue,
                groupID: syntheticGroupID,
                conditionID: nil,
                invalidValue: $0.uuidString
            )
        }
        return MailProjectValidationReport(
            issues: report.issues + extra,
            invalidGroupIDs: report.invalidGroupIDs.union([syntheticGroupID]),
            invalidConditionIDs: report.invalidConditionIDs,
            automaticMatchingIsSuspended: true
        )
    }

    private static func retainedAutomaticEvaluation(
        from membership: MailProjectMembershipSnapshot?,
        validation: MailProjectValidationReport,
        pendingFacets: Set<MailProjectRuleFacet>
    ) -> MailProjectAutomaticEvaluation {
        guard validation.automaticMatchingIsSuspended == false else {
            return .invalid(validation)
        }
        guard let rule = membership?.provenance.rule,
              validation.invalidGroupIDs.contains(rule.matchingGroupID) == false else {
            return .pending(requiredFacets: pendingFacets)
        }
        return .member(rule)
    }

    private static func evaluatedMessage(
        preserving membership: MailProjectMembershipSnapshot
    ) -> MailProjectEvaluatedMessage {
        MailProjectEvaluatedMessage(
            messageID: membership.messageID,
            finalDecision: .included(
                source: membership.source,
                provenance: membership.provenance
            ),
            sourceFingerprint: membership.sourceFingerprint,
            evaluatedAt: membership.evaluatedAt
        )
    }

    private static func projection(
        _ decision: MailProjectFinalMembershipDecision,
        sourceFingerprint: String,
        matches membership: MailProjectMembershipSnapshot
    ) -> Bool {
        guard case let .included(source, provenance) = decision else { return false }
        return source == membership.source
            && provenance == membership.provenance
            && sourceFingerprint == membership.sourceFingerprint
    }

    private static func validationError(_ report: MailProjectValidationReport) -> String {
        report.issues.map { issue in
            [issue.code.rawValue, issue.groupID.uuidString, issue.invalidValue]
                .compactMap { $0 }
                .joined(separator: ":")
        }.joined(separator: "|")
    }

    private static func freshContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private static func groupOrder(_ lhs: MailProjectRuleGroup, _ rhs: MailProjectRuleGroup) -> Bool {
        lhs.sortIndex != rhs.sortIndex ? lhs.sortIndex < rhs.sortIndex : uuidOrder(lhs.id, rhs.id)
    }

    private static func conditionOrder(
        _ lhs: MailProjectRuleCondition,
        _ rhs: MailProjectRuleCondition
    ) -> Bool {
        lhs.sortIndex != rhs.sortIndex ? lhs.sortIndex < rhs.sortIndex : uuidOrder(lhs.id, rhs.id)
    }

    private static func decisionOrder(_ lhs: MailProjectDecision, _ rhs: MailProjectDecision) -> Bool {
        if lhs.targetKindRawValue != rhs.targetKindRawValue {
            return lhs.targetKindRawValue < rhs.targetKindRawValue
        }
        if lhs.targetID != rhs.targetID { return uuidOrder(lhs.targetID, rhs.targetID) }
        return uuidOrder(lhs.id, rhs.id)
    }

    private static let metadataFacets: Set<MailProjectRuleFacet> = [
        .semanticTag,
        .language,
    ]
}

private enum ProjectWorkScope: Sendable, Equatable {
    case full
    case messages(Set<UUID>, Set<MailProjectRuleFacet>)

    func union(_ other: Self?) -> Self {
        guard let other else { return self }
        switch (self, other) {
        case (.full, _), (_, .full):
            return .full
        case let (.messages(lhsIDs, lhsFacets), .messages(rhsIDs, rhsFacets)):
            return .messages(lhsIDs.union(rhsIDs), lhsFacets.union(rhsFacets))
        }
    }

    var repositoryScope: MailProjectReconciliationScope {
        switch self {
        case .full: .full
        case let .messages(messageIDs, _): .messages(messageIDs)
        }
    }
}

private struct ProjectInput: Sendable {
    let configuration: MailProjectConfigurationSnapshot
    let validation: MailProjectValidationReport
    let dependencies: MailProjectDependencySet
    let revision: Int
}

private struct RoutingSnapshot: Sendable {
    let index: ManualProjectDependencyIndex
    let inputs: [UUID: ProjectInput]
    let revisions: [UUID: Int]
    let errors: [UUID: CoordinatorReadError]
    let unindexableProjectIDs: Set<UUID>
}

private struct PreparedReconciliation: Sendable {
    let projectID: UUID
    let revision: Int
    let validation: MailProjectValidationReport
    let evaluated: [MailProjectEvaluatedMessage]
    let sourceStateFingerprints: [UUID: String]
    let scope: ProjectWorkScope
}

private enum CoordinatorReadError: Error, Sendable {
    case missingConfiguration(UUID)
    case configuration(UUID, String)
    case unstableMessageSource(UUID)
}

private struct MessageSnapshotGeneration: Sendable {
    let snapshot: MailProjectMessageSnapshot?
    let sourceStateFingerprint: String
}

private final class ManualProjectCancellationToken: @unchecked Sendable {
    private let cancelled = Mutex(false)

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    func check() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
}
