import Foundation
import SwiftData
import OhiaCore
import OhiaML
import OhiaScheduler

nonisolated enum ReplySourcePreparationAdoptionResult: Equatable, Sendable {
    case adopted
    case existingDraft
    case preparationInProgress
    case unavailable
}

nonisolated struct ReplySourcePreparationAssessment: Sendable {
    let messageID: UUID
    let fingerprint: String
    let metadataStamp: String
}

nonisolated enum ReplySourcePreparationAssessmentError: Error {
    case staleInput
}

/// Transfers a complete pre-presentation reply snapshot only when the user
/// explicitly enters Composer. Store-keyed lookups are authoritative because
/// worker-process saves can leave this context's relationships stale.
@MainActor
enum ReplySourcePreparationAdopter {
    private enum ReadyArtifacts {
        case questions(ComposerInterviewState)
        case generatedDraft(PreparedReplyDraftPayload, ComposerInterviewState)
    }

    static func adoptReadySources(
        for message: Message,
        context: ModelContext,
        assessment: ReplySourcePreparationAssessment? = nil
    ) throws -> ReplySourcePreparationAdoptionResult {
        if let assessment {
            guard assessment.messageID == message.id,
                  assessment.metadataStamp == ReplySourcePreparationFingerprint.metadataStamp(for: message),
                  !message.isTrashed, message.composerQueueOverride != .exclude else {
                throw ReplySourcePreparationAssessmentError.staleInput
            }
        }
        let currentFingerprint = assessment?.fingerprint
            ?? ReplySourcePreparationFingerprint.value(for: message)
        let preparations = try storedPreparations(
            messageID: message.id,
            context: context
        )

        let existingDraft: Draft?
        if let relationshipDraft = message.draft {
            existingDraft = relationshipDraft
        } else {
            existingDraft = try storedDraft(messageID: message.id, context: context)
        }
        if let existingDraft {
            var changed = false
            var consumedPreparationIDs = Set<UUID>()
            if message.draft?.id != existingDraft.id {
                message.draft = existingDraft
                changed = true
            }
            // An exhausted preparation used to be adopted as a terminal
            // interview and immediately drafted without any author decision.
            // Recover only an untouched, failed first draft;
            // never replace an answered interview or an existing authored body.
            if existingDraft.status == .pending,
               existingDraft.resolvedStage == DraftStage.generating,
               existingDraft.generationFailureCount != nil,
               existingDraft.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               existingDraft.orderedRevisions.isEmpty,
               let state = ComposerInterviewStateCoding.decode(existingDraft.interviewStateJSON),
               let exhausted = preparations.first(where: {
                   $0.inputFingerprint == currentFingerprint
                       && $0.contractVersion == ReplySourcePreparationFingerprint.contractVersion
                       && $0.statusRaw == ReplySourcePreparationStatus.ready
                       && needsQuestionRecovery(in: $0, state: state)
               }) {
                existingDraft.interviewStateJSON = nil
                existingDraft.stageRaw = DraftStage.evaluatingSources
                existingDraft.clearGenerationBackoff()
                try ComposerQueueMembership.stageTargetedDraftJob(messageID: message.id, context: context)
                consumedPreparationIDs.insert(exhausted.id)
                changed = true
            }
            if existingDraft.status == .pending,
               existingDraft.resolvedStage == DraftStage.collectingSources,
               existingDraft.hasCompletedAutomaticSourceResearch,
               validSourcesJSON(existingDraft.sourcesJSON) {
                existingDraft.stageRaw = DraftStage.evaluatingSources
                try ComposerQueueMembership.stageTargetedDraftJob(
                    messageID: message.id,
                    context: context
                )
                changed = true
            }
            changed = deletePreparations(preparations.filter {
                consumedPreparationIDs.contains($0.id)
                    || $0.inputFingerprint != currentFingerprint
                    || $0.contractVersion != ReplySourcePreparationFingerprint.contractVersion
                    || readyArtifacts(in: $0) == nil
            }, context: context) || changed
            if assessment == nil {
                changed = try deletePendingPreparationJobs(
                    messageID: message.id,
                    context: context
                ) || changed
            }
            if changed {
                try context.save()
            }
            return .existingDraft
        }

        // The conversation's reply already exists as a pending Draft on an
        // older email, which moves to this one. Adopting here would make it
        // two Drafts for one conversation.
        if ReplySourcePreparationEligibility.otherEmailHoldingUnsentReplyDraft(
            for: message,
            context: context
        ) != nil {
            return .unavailable
        }

        // Recheck completion before reusing a cache. Foreground replies need
        // explicit Composer admission, but need not have been triaged as an
        // obligation. An action saved during the await still wins.
        guard ReplySourcePreparationEligibility.canRetainCompletedPreparation(message, context: context),
              ReplySourcePreparationEligibility.isEligible(message, context: context)
                || message.composerQueueOverride == .include else {
            try ReplySourcePreparationCoordinator().cancel(
                messageIDs: [message.id],
                context: context
            )
            return .unavailable
        }

        let currentRows = preparations.filter {
            $0.inputFingerprint == currentFingerprint
                && $0.contractVersion == ReplySourcePreparationFingerprint.contractVersion
        }
        let ready = currentRows
            .filter {
                $0.statusRaw == ReplySourcePreparationStatus.ready
                    && readyArtifacts(in: $0) != nil
            }
            .sorted(by: preparationPreference)
            .first

        if let ready, let artifacts = readyArtifacts(in: ready) {
            var generatedDraft: Draft?
            var consumedExhaustedPreparation = false
            switch artifacts {
            case .questions(let interviewState):
                let draft = Draft(
                    message: message,
                    replyText: "",
                    confidence: 0,
                    sourceThreadCount: ready.sourceThreadCount,
                    sourceExemplarCount: 0,
                    styleMatch: 0
                )
                draft.sourcesJSON = ready.sourcesJSON
                draft.sourceThreadCoverageJSON = ready.sourceThreadCoverageJSON
                draft.sourceContextTokenCount = ready.sourceContextTokenCount
                draft.sourceContextTokenLimit = ready.sourceContextTokenLimit
                draft.sourceContextFitJSON = ready.sourceContextFitJSON
                let needsGeneration = ComposerInterviewExecutor.project(interviewState).currentNode == nil
                let needsRecovery = needsQuestionRecovery(in: ready, state: interviewState)
                consumedExhaustedPreparation = needsRecovery
                draft.stageRaw = needsRecovery ? DraftStage.evaluatingSources
                    : (needsGeneration ? DraftStage.generating : DraftStage.collectingAnswers)
                draft.completeAutomaticSourceResearch()
                draft.sourcesCuratedAt = nil
                draft.fromIdentityID = IdentityResolver.resolveReplyIdentity(message: message)?.id
                draft.signatureSlotID = message.account?.defaultSignatureSlot?.id
                draft.interviewStateJSON = needsRecovery ? nil : ComposerInterviewStateCoding.encode(interviewState)
                context.insert(draft)
                message.draft = draft
                if needsGeneration || needsRecovery {
                    try ComposerQueueMembership.stageTargetedDraftJob(messageID: message.id, context: context)
                }

            case .generatedDraft(let payload, _):
                generatedDraft = DraftGenerationOrchestrator.materializePreparedReply(
                    payload,
                    preparation: ready,
                    message: message,
                    context: context
                )
            }

            // Keep successful immutable baselines for re-entry. An exhausted
            // baseline is consumed once: retaining it would let refresh polling
            // restart recovery after every subsequent foreground failure.
            _ = deletePreparations(preparations.filter {
                consumedExhaustedPreparation || $0.id != ready.id
            }, context: context)
            message.replySourcePreparation = consumedExhaustedPreparation ? nil : ready
            if assessment == nil {
                _ = try deletePendingPreparationJobs(
                    messageID: message.id,
                    context: context
                )
            }
            if let generatedDraft {
                generatedDraft.message = message
                message.draft = generatedDraft
            }
            try context.save()
            return .adopted
        }

        // A current preemptive preparation is authoritative while it is
        // pending or running. Composer must wait for and poll this row rather
        // than creating a Draft shell that would supersede the preparation
        // and restart the same source compilation from the foreground lane.
        if currentRows.contains(where: {
            $0.statusRaw == ReplySourcePreparationStatus.pending
                || $0.statusRaw == ReplySourcePreparationStatus.compilingSources
                || $0.statusRaw == ReplySourcePreparationStatus.formulatingQuestions
                || $0.statusRaw == ReplySourcePreparationStatus.drafting
                || $0.statusRaw == ReplySourcePreparationStatus.retryWaiting
        }) {
            if assessment == nil {
                try promoteActivePreparationJob(
                    messageID: message.id,
                    fingerprint: currentFingerprint,
                    context: context
                )
            }
            return .preparationInProgress
        }

        let hasStaleRow = preparations.contains {
            $0.inputFingerprint != currentFingerprint
                || $0.contractVersion != ReplySourcePreparationFingerprint.contractVersion
        }
        let corruptCurrentRows = currentRows.filter {
            switch $0.statusRaw {
            case ReplySourcePreparationStatus.pending,
                 ReplySourcePreparationStatus.compilingSources,
                 ReplySourcePreparationStatus.formulatingQuestions,
                 ReplySourcePreparationStatus.drafting,
                 ReplySourcePreparationStatus.retryWaiting:
                return false
            case ReplySourcePreparationStatus.ready:
                return readyArtifacts(in: $0) == nil
            default:
                return true
            }
        }

        guard hasStaleRow || corruptCurrentRows.isEmpty == false else {
            return .unavailable
        }

        if corruptCurrentRows.isEmpty == false {
            _ = deletePreparations(corruptCurrentRows, context: context)
            context.processPendingChanges()
        }
        _ = try ReplySourcePreparationCoordinator().reconcile(
            messageIDs: [message.id],
            origin: .alreadyVisibleManualAction,
            durablyAnnouncedMessageIDs:
                NewMailArrivalLedger.shared.durablyAnnouncedMessageIDs(),
            context: context
        )
        return .unavailable
    }

    /// Runs only on a background read worker with its own context. Job
    /// maintenance changes no Message or Draft fields, so it cannot save over
    /// an editor's buffered text while the UI remains interactive.
    nonisolated static func assess(
        messageID: UUID,
        container: ModelContainer,
        isCurrent: @Sendable () -> Bool
    ) throws -> ReplySourcePreparationAssessment? {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        guard let message = try context.fetch(descriptor).first,
              !message.isTrashed, message.composerQueueOverride != .exclude else { return nil }
        let fingerprint = ReplySourcePreparationFingerprint.value(for: message)
        let stamp = ReplySourcePreparationFingerprint.metadataStamp(for: message)
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let preparations = try storedPreparations(messageID: messageID, context: context)
        if try storedDraft(messageID: messageID, context: context) != nil
            || preparations.contains(where: {
                $0.inputFingerprint == fingerprint
                    && $0.contractVersion == ReplySourcePreparationFingerprint.contractVersion
                    && $0.statusRaw == ReplySourcePreparationStatus.ready
            }) {
            if try deletePendingPreparationJobs(messageID: messageID, context: context) {
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                try context.save()
            }
        } else if ReplySourcePreparationEligibility.isEligible(message, context: context),
                  preparations.contains(where: {
            $0.inputFingerprint == fingerprint
                && $0.contractVersion == ReplySourcePreparationFingerprint.contractVersion
                && [ReplySourcePreparationStatus.pending,
                    ReplySourcePreparationStatus.compilingSources,
                    ReplySourcePreparationStatus.formulatingQuestions,
                    ReplySourcePreparationStatus.drafting,
                    ReplySourcePreparationStatus.retryWaiting].contains($0.statusRaw)
        }) {
            try promoteActivePreparationJob(
                messageID: messageID, fingerprint: fingerprint,
                context: context, isCurrent: isCurrent
            )
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        return ReplySourcePreparationAssessment(
            messageID: messageID, fingerprint: fingerprint, metadataStamp: stamp
        )
    }

    nonisolated private static func storedDraft(
        messageID: UUID,
        context: ModelContext
    ) throws -> Draft? {
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { draft in
                draft.message?.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    nonisolated private static func storedPreparations(
        messageID: UUID,
        context: ModelContext
    ) throws -> [ReplySourcePreparation] {
        try context.fetch(
            FetchDescriptor<ReplySourcePreparation>(
                predicate: #Predicate<ReplySourcePreparation> {
                    $0.messageId == messageID
                }
            )
        )
    }

    @discardableResult
    private static func deletePreparations(
        _ preparations: [ReplySourcePreparation],
        context: ModelContext
    ) -> Bool {
        guard preparations.isEmpty == false else { return false }
        for preparation in preparations {
            if preparation.message?.replySourcePreparation?.id == preparation.id {
                preparation.message?.replySourcePreparation = nil
            }
            preparation.message = nil
            context.delete(preparation)
        }
        return true
    }

    @discardableResult
    nonisolated private static func deletePendingPreparationJobs(
        messageID: UUID,
        context: ModelContext
    ) throws -> Bool {
        let fetched = try context.fetch(
            FetchDescriptor<Job>(
                predicate: #Predicate<Job> { $0.messageId == messageID }
            )
        )
        let inserted = context.insertedModelsArray.compactMap { $0 as? Job }
        var seen = Set<UUID>()
        var changed = false
        for job in fetched + inserted where seen.insert(job.id).inserted {
            guard job.type == .prepareReplySources,
                  job.messageId == messageID,
                  job.status == .pending else {
                continue
            }
            context.delete(job)
            changed = true
        }
        return changed
    }

    /// Entering Composer transfers the current preparation from background
    /// intake to the interactive lane without creating a competing Draft.
    /// Match the durable payload so an obsolete preparation job for the same
    /// message cannot inherit foreground priority.
    nonisolated private static func promoteActivePreparationJob(
        messageID: UUID,
        fingerprint: String,
        context: ModelContext,
        isCurrent: @Sendable () -> Bool = { true }
    ) throws {
        let expectedPayload = ReplySourcePreparationJobPayload(
            messageID: messageID,
            fingerprint: fingerprint,
            contractVersion: ReplySourcePreparationFingerprint.contractVersion
        )
        let fetched = try context.fetch(
            FetchDescriptor<Job>(
                predicate: #Predicate<Job> { $0.messageId == messageID }
            )
        )
        let inserted = context.insertedModelsArray.compactMap { $0 as? Job }
        var seen = Set<UUID>()
        var changed = false
        for job in fetched + inserted where seen.insert(job.id).inserted {
            guard job.type == .prepareReplySources,
                  job.messageId == messageID,
                  job.status == .pending || job.status == .running,
                  ReplySourcePreparationJobPayload.decode(job.payload) == expectedPayload,
                  job.priority > ComposerDraftScheduling.userInitiatedPriority else {
                continue
            }
            job.priority = ComposerDraftScheduling.userInitiatedPriority
            changed = true
        }
        if changed {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try context.save()
        }
    }

    private static func validSourcesJSON(_ json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8) else { return false }
        return (try? JSONDecoder().decode([ComposerSource].self, from: data)) != nil
    }

    private static func readyArtifacts(
        in preparation: ReplySourcePreparation
    ) -> ReadyArtifacts? {
        guard preparation.statusRaw == ReplySourcePreparationStatus.ready,
              preparation.sourceThreadCount >= 0,
              validSourcesJSON(preparation.sourcesJSON),
              (0...1).contains(preparation.questionCount),
              let state = ComposerInterviewStateCoding.decode(
                  preparation.interviewStateJSON
              ) else {
            return nil
        }
        let projection = ComposerInterviewExecutor.project(state)

        if preparation.questionCount == 1 {
            guard projection.currentNode != nil,
                  preparation.generatedDraftJSON == nil else { return nil }
            return .questions(state)
        }

        guard projection.currentNode == nil else { return nil }
        // A foreground Draft can finish its interview before body generation.
        // Reuse that completed interview and generate only the missing body.
        if preparation.generatedDraftJSON == nil { return .questions(state) }
        guard let payload = decodePreparedDraft(preparation.generatedDraftJSON) else { return nil }
        return .generatedDraft(payload, state)
    }

    /// Failure is not evidence that the reply needs no decisions. A fresh
    /// foreground evaluation can recover the questions or present the normal
    /// invalid-plan state; it must not authorize a content-free generation.
    /// Recovery consumes the exhausted preparation so a subsequent failure
    /// cannot restart evaluation on every refresh.
    private static func needsQuestionRecovery(
        in preparation: ReplySourcePreparation,
        state: ComposerInterviewState
    ) -> Bool {
        preparation.generatedDraftJSON == nil
            && (state.planningOutcome == .invalid
                || preparation.failureCount >= ReplySourcePreparationCoordinator.maximumTerminalFailures)
            && state.baseProtocol.questionNodes.isEmpty
            && state.answers.isEmpty
            && state.acceptedPatches.isEmpty
            && (state.carriedDecisions ?? []).isEmpty
    }

    private static func decodePreparedDraft(
        _ json: String?
    ) -> PreparedReplyDraftPayload? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PreparedReplyDraftPayload.self, from: data)
    }

    private static func preparationPreference(
        _ lhs: ReplySourcePreparation,
        _ rhs: ReplySourcePreparation
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
