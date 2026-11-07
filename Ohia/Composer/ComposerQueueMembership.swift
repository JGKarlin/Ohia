// Ohia/Composer/ComposerQueueMembership.swift
// Single write path for user decisions about Composer queue membership:
// the node context menu's Composer queue item, the queue pane's remove
// affordance, and the Composer's "No Reply Needed" command all route here
// without changing the message's independently resolved reply obligation.

import Foundation
import SwiftData
import OhiaCore
import OhiaML
import OhiaScheduler

@MainActor
enum ComposerQueueMembership {

    /// Whether the node context menu's Composer queue checkmark should be on:
    /// the message is queue-eligible and its draft (when one exists) is
    /// still pending. Sent, confirmed, and rejected drafts read as "handled".
    static func isInQueue(_ message: Message) -> Bool {
        guard message.isComposerQueueEligible else { return false }
        guard let draft = resolvedDraft(for: message) else { return true }
        return draft.status == .pending
    }

    /// Whether the Composer queue toggle can do anything for this message:
    /// no draft yet, a pending draft (can reject), or a rejected one (can
    /// revive). Confirmed and sent drafts are settled — the reply happened —
    /// so the toggle disables rather than silently no-op.
    static func canToggleNeedsReply(_ message: Message) -> Bool {
        guard !message.isTrashed else { return false }
        guard let draft = resolvedDraft(for: message) else { return true }
        return draft.status == .pending || draft.status == .rejected
    }

    /// Adds or removes a message from the Composer reply queue.
    ///
    /// Adding sets the explicit `include` override. A previously-rejected
    /// draft is revived when it carries
    /// real content (questions, body text, or revisions); an empty rejected
    /// shell is deleted so the pipeline seeds fresh clarifying questions. When
    /// the conversation's live reply Draft is on another email, a rejected
    /// draft here is removed instead, since a conversation has one reply. A
    /// discarded draft is never revived — it is removed so re-adding starts
    /// with a new Draft that can reuse unchanged prepared sources and questions.
    /// Drafts already confirmed or sent are left untouched — the reply
    /// happened, and the queue row stays hidden until new mail re-triages.
    ///
    /// Removing sets the explicit `exclude` override, preserves the reply
    /// obligation, and discards any still-pending draft. Drafts with a provider
    /// Drafts copy stay as detached cleanup tombstones until the sync worker
    /// deletes the remote copy; local-only drafts are deleted immediately.
    /// Removing a conversation's queue item removes the conversation: the
    /// item's reply target and the email still holding its Draft are both
    /// excluded.
    static func setNeedsReply(
        _ needsReply: Bool,
        message: Message,
        context: ModelContext,
        attachmentStore: ComposerAttachmentStore = ComposerAttachmentStore(),
        inlinePhotoStore: ComposerInlinePhotoStore = ComposerInlinePhotoStore(),
        stageDraftSync: ComposerDraftSyncStager = ComposerDraftSyncScheduler.stageDraftSync,
        saveContext: ComposerContextSaver = ComposerPersistence.save,
        postMessageAttentionChanged: (Set<UUID>) -> Void = { messageIDs in
            NotificationCenter.default.post(
                name: .ohiaMessageAttentionChanged,
                object: nil,
                userInfo: MessageAttentionNotificationCoding.userInfo(messageIDs: messageIDs)
            )
        }
    ) throws {
        // Dismissing a conversation's queue item dismisses the conversation:
        // its reply target and the email carrying the item are both excluded,
        // so it has no item until a newer qualifying email arrives.
        let dismissedCompanions = needsReply ? [] : conversationCompanions(dismissing: message)
        // Re-adding an email whose conversation's reply already lives on
        // another email keeps that one reply; reviving this email's rejected
        // draft would make it two, so that draft is removed instead.
        let conversationReplyElsewhere = needsReply
            && ReplySourcePreparationEligibility.otherEmailHoldingUnsentReplyDraft(
                for: message,
                context: context
            ) != nil
        let draftForMutation = resolvedDraft(for: message, context: context)
        let pendingTargetedDraftJobs = needsReply
            ? []
            : try pendingTargetedDraftJobs(for: message.id, context: context)
        let mutationSnapshot = MutationSnapshot(message: message, draft: draftForMutation)
        let preexistingInsertedSyncJobIDs = ComposerDiscardTransaction.insertedSyncJobIDs(
            in: context
        )
        var cleanupOwnerIDs: Set<UUID> = []
        var cachedPreparation: ReplySourcePreparation?
        do {
            if !needsReply, let draft = draftForMutation, draft.status == .pending {
                cachedPreparation = try DraftGenerationOrchestrator.cacheReplyPreparationIfCurrent(
                    from: draft, context: context
                )
            }
            if needsReply {
                message.composerQueueOverride = .include
                if let draft = draftForMutation {
                    // Heal a stale-nil relationship before branching: the
                    // trailing generate gate reads `message.draft`, and a
                    // store-resolved draft must count as the message's live
                    // draft — otherwise re-adding enqueues a spurious
                    // generation pass over the draft that already exists.
                    if message.draft == nil { message.draft = draft }
                    if draft.status == .rejected {
                        if conversationReplyElsewhere,
                           let ownerID = try removeDiscardedDraft(
                               draft,
                               from: message,
                               context: context,
                               stageDraftSync: stageDraftSync
                           ) {
                            // The conversation's live reply supersedes it;
                            // left in place it would also block that reply
                            // from moving here (one Draft per email).
                            cleanupOwnerIDs.insert(ownerID)
                        } else if isEmptyShell(draft) {
                            message.draft = nil
                            cleanupOwnerIDs.insert(draft.id)
                            context.delete(draft)
                        } else {
                            draft.status = .pending
                        }
                    } else if draft.status == .discarded,
                              let ownerID = try removeDiscardedDraft(
                                  draft,
                                  from: message,
                                  context: context,
                                  stageDraftSync: stageDraftSync
                              ) {
                        cleanupOwnerIDs.insert(ownerID)
                    }
                }
                try saveContext(context)
            } else {
                message.composerQueueOverride = .exclude
                if let draft = draftForMutation,
                   draft.status == .pending,
                   let ownerID = try discardPendingDraft(
                       draft,
                       from: message,
                       context: context,
                       stageDraftSync: stageDraftSync
                   ) {
                    cleanupOwnerIDs.insert(ownerID)
                }
                for job in pendingTargetedDraftJobs {
                    context.delete(job)
                }
                try saveContext(context)
            }
        } catch {
            if let cachedPreparation { context.delete(cachedPreparation) }
            mutationSnapshot.restore(message: message, context: context)
            restoreDeletedJobs(pendingTargetedDraftJobs, context: context)
            ComposerDiscardTransaction.removeSyncJobsInserted(
                after: preexistingInsertedSyncJobIDs,
                context: context
            )
            throw error
        }

        defer {
            for ownerID in cleanupOwnerIDs {
                ComposerDraftAssetCleanup.deleteAll(
                    ownerID: ownerID,
                    attachmentStore: attachmentStore,
                    inlinePhotoStore: inlinePhotoStore
                )
            }
        }

        let messageIDs: Set<UUID> = [message.id]
        // Completed preparation survives queue removal. An open Needs Reply
        // obligation owns its background work independently of Composer;
        // otherwise removal cancels unfinished work until explicit re-entry.
        let preparationCoordinator = ReplySourcePreparationCoordinator()
        if needsReply == false,
           ReplySourcePreparationEligibility.isEligible(message, context: context) == false {
            // An uninterpreted message normally waits for triage before its
            // eligibility can be decided. Here the user has explicitly removed
            // the only reply obligation, so cancel immediately instead of
            // manufacturing a summarize prerequisite for resolved work.
            try preparationCoordinator.cancel(messageIDs: messageIDs, context: context)
        } else {
            try preparationCoordinator.reconcile(
                messageIDs: messageIDs,
                origin: .alreadyVisibleManualAction,
                durablyAnnouncedMessageIDs:
                    NewMailArrivalLedger.shared.durablyAnnouncedMessageIDs(),
                context: context
            )
        }
        if needsReply,
           !ReplySourcePreparationEligibility.isEligible(message, context: context) {
            // Re-entry adopts completed foreground preparation before the
            // queue can start compiling the same non-triaged reply again.
            _ = try ReplySourcePreparationAdopter.adoptReadySources(for: message, context: context)
        }
        postMessageAttentionChanged(messageIDs)

        for companion in dismissedCompanions where companion.composerQueueOverride != .exclude {
            try setNeedsReply(
                false,
                message: companion,
                context: context,
                attachmentStore: attachmentStore,
                inlinePhotoStore: inlinePhotoStore,
                stageDraftSync: stageDraftSync,
                saveContext: saveContext,
                postMessageAttentionChanged: postMessageAttentionChanged
            )
        }
    }

    /// The other emails a "No Reply Needed" on `message` dismisses with it:
    /// when `message` carries its conversation's queue item or is its reply
    /// target, the other of the two (the target newer than an email still
    /// holding the conversation's Draft, or that holder). Excluding only one
    /// would hand the conversation straight back as a new item.
    private static func conversationCompanions(dismissing message: Message) -> [Message] {
        guard message.thread != nil else { return [] }
        let resolution = message.composerConversationQueueResolution(
            automaticTriageQueueingEnabled: ComposerQueueIntakePreference.automaticTriageQueueingEnabled()
        )
        guard let item = resolution.item,
              let target = resolution.target,
              item.id == message.id || target.id == message.id else { return [] }
        return [item, target].filter { $0.id != message.id }
    }

    /// Returns only unclaimed user work for this reply. A running job is left
    /// alone because its model pass owns that lifecycle; the generation
    /// orchestrator re-reads committed state before it can publish anything.
    private static func pendingTargetedDraftJobs(
        for messageID: UUID,
        context: ModelContext
    ) throws -> [Job] {
        let inserted = context.insertedModelsArray.compactMap { $0 as? Job }
        var jobsByID: [UUID: Job] = [:]
        for job in try JobFetch.pending(context: context) + inserted
            where job.type == .generateDraft
                && job.status == .pending
                && job.messageId == messageID {
            jobsByID[job.id] = job
        }
        return Array(jobsByID.values)
    }

    private static func restoreDeletedJobs(_ jobs: [Job], context: ModelContext) {
        var restoredAny = false
        for job in jobs
            where context.deletedModelsArray.contains(where: { ($0 as? Job) === job }) {
            context.insert(job)
            restoredAny = true
        }
        if restoredAny {
            context.processPendingChanges()
        }
    }

    /// Enqueues a user-initiated `.generateDraft` job targeted at one
    /// message. The scheduler's Composer lane claims these ahead of every
    /// other Qwen job, and the orchestrator services the targeted message
    /// first in all three passes. Deduplicates against an already-pending
    /// targeted job for the same message.
    static func enqueueTargetedDraftJob(
        messageID: UUID,
        context: ModelContext
    ) throws {
        if try stageTargetedDraftJob(messageID: messageID, context: context) {
            try context.save()
        }
    }

    /// Stages the same targeted user-initiated job without saving. Adoption
    /// uses this seam so the new Draft, preparation deletion, and question
    /// evaluation job commit atomically. Check inserted rows explicitly:
    /// SQLite-backed `JobFetch` can only see the last durable save.
    @discardableResult
    static func stageTargetedDraftJob(
        messageID: UUID,
        context: ModelContext
    ) throws -> Bool {
        let inserted = context.insertedModelsArray.compactMap { $0 as? Job }
        let pending = try JobFetch.pending(context: context)
        let alreadyQueued = (pending + inserted).contains { job in
            job.type == .generateDraft
                && job.status == .pending
                && job.priority <= ComposerDraftScheduling.userInitiatedPriority
                && job.messageId == messageID
        }
        guard !alreadyQueued else { return false }
        JobQueue().stage(
            type: .generateDraft,
            priority: ComposerDraftScheduling.userInitiatedPriority,
            messageId: messageID,
            context: context
        )
        return true
    }

    /// The message's draft through both lookups. A registered `Message`'s
    /// `draft` relationship can be a stale nil when the generative worker
    /// created the row in its own process (see `storedDraft`), so a
    /// relationship miss falls back to the store-keyed fetch — otherwise
    /// queue removal marks the message handled while the pending draft
    /// keeps re-publishing to the provider Drafts mailbox.
    private static func resolvedDraft(
        for message: Message,
        context: ModelContext? = nil
    ) -> Draft? {
        if let draft = message.draft { return draft }
        guard let context = context ?? message.modelContext else { return nil }
        return storedDraft(for: message.id, context: context)
    }

    /// The message whose Composer queue item covers `messageID`'s
    /// conversation. A conversation is one item, replying to its newest
    /// qualifying email (or carried by the older email still holding its
    /// pending reply Draft), so a request to open an earlier email it covers
    /// opens that item. An email that is its own item, holds its own pending
    /// Draft, or whose conversation has no item, maps to itself.
    static func queueItemMessageID(for messageID: UUID, context: ModelContext) -> UUID {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == messageID })
        descriptor.fetchLimit = 1
        guard let message = (try? context.fetch(descriptor))?.first,
              !message.isTrashed,
              !message.isSentByUser,
              message.thread != nil,
              !message.holdsUnsentReplyDraft,
              let item = message.composerConversationQueueResolution(
                  automaticTriageQueueingEnabled: ComposerQueueIntakePreference.automaticTriageQueueingEnabled()
              ).item else {
            return messageID
        }
        return item.id
    }

    /// Store-keyed Draft lookup for a message. Used wherever the app might
    /// create a Draft row that the generative worker could also be creating
    /// in its own process — a registered `Message`'s `draft` relationship
    /// can be a stale nil while the row already exists in the store.
    static func storedDraft(for messageID: UUID, context: ModelContext) -> Draft? {
        var descriptor = FetchDescriptor<Draft>(predicate: #Predicate<Draft> { draft in
            draft.message?.id == messageID
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// A rejected draft with no interview, body, or version history —
    /// the shell the old dismiss path created just to mark "no reply". Safe
    /// to delete so a re-added message gets fresh clarifying questions.
    private static func isEmptyShell(_ draft: Draft) -> Bool {
        draft.replyText.isEmpty
            && draft.orderedRevisions.isEmpty
            && (draft.interviewStateJSON?.isEmpty ?? true)
            && draft.bodyHTML?.contains("\(ComposerInlinePhotoToken.scheme)://") != true
    }

    private static func discardPendingDraft(
        _ draft: Draft,
        from message: Message,
        context: ModelContext,
        stageDraftSync: ComposerDraftSyncStager
    ) throws -> UUID? {
        guard draft.status == .pending else { return nil }
        if hasProviderDraftLocation(draft),
           let cleanupAccountID = draft.mailboxDraftAccountID ?? message.accountID ?? message.account?.id {
            draft.status = .discarded
            draft.mailboxDraftAccountID = cleanupAccountID
            try stageDraftSync(draft, context)
            scrubDraftContent(draft, context: context)
            draft.message = nil
            message.draft = nil
        } else {
            message.draft = nil
            context.delete(draft)
        }
        return draft.id
    }

    private static func removeDiscardedDraft(
        _ draft: Draft,
        from message: Message,
        context: ModelContext,
        stageDraftSync: ComposerDraftSyncStager
    ) throws -> UUID? {
        if hasProviderDraftLocation(draft),
           let cleanupAccountID = draft.mailboxDraftAccountID ?? message.accountID ?? message.account?.id {
            draft.mailboxDraftAccountID = cleanupAccountID
            try stageDraftSync(draft, context)
            scrubDraftContent(draft, context: context)
            draft.message = nil
            message.draft = nil
        } else {
            message.draft = nil
            context.delete(draft)
        }
        return draft.id
    }

    private static func hasProviderDraftLocation(_ draft: Draft) -> Bool {
        draft.mailboxDraftFolderPath != nil
            && (draft.mailboxDraftUID != nil || draft.mailboxDraftMessageIDHeader != nil)
    }

    private static func scrubDraftContent(_ draft: Draft, context: ModelContext) {
        draft.replyText = ""
        draft.confidence = 0
        draft.citationsJSON = nil
        draft.gapsJSON = nil
        draft.deliverablesJSON = nil
        draft.replyAttachmentPathsJSON = nil
        draft.interviewStateJSON = nil
        draft.decisionResearchOverlayJSON = nil
        draft.decisionHistoryJSON = nil
        draft.sourcesJSON = nil
        draft.sourceContextTokenCount = nil
        draft.sourceContextFitJSON = nil
        draft.sourceContextTokenLimit = nil
        draft.sourceContextMeasurementRequestedAt = nil
        draft.automaticSourceResearchStateRaw = nil
        draft.automaticSourceResearchInputFingerprint = nil
        draft.sourcesCuratedAt = nil
        draft.sourceThreadCoverageJSON = nil
        draft.sourceThreadCount = 0
        draft.sourceExemplarCount = 0
        draft.styleMatch = 0
        draft.stageRaw = nil
        draft.bodyHTML = nil
        draft.inlinePhotosJSON = nil
        draft.pendingInstruction = nil
        draft.draftingInstruction = nil
        draft.appliedRuleIDsJSON = nil
        draft.personalizationJSON = nil
        draft.modelVersion = nil
        for revision in draft.orderedRevisions {
            context.delete(revision)
        }
        draft.revisions = []
        draft.baseRevisionID = nil
    }

    private struct MutationSnapshot {
        let composerQueueOverrideRaw: String?
        let requiresReply: Bool
        let messageDraft: Draft?
        let draft: Draft?
        let draftStatus: DraftStatus?
        let draftMessage: Message?
        let mailboxDraftAccountID: UUID?
        let replyText: String?
        let confidence: Double?
        let citationsJSON: String?
        let gapsJSON: String?
        let deliverablesJSON: String?
        let replyAttachmentPathsJSON: String?
        let interviewStateJSON: String?
        let decisionResearchOverlayJSON: String?
        let decisionHistoryJSON: String?
        let sourcesJSON: String?
        let sourceContextTokenCount: Int?
        let sourceContextTokenLimit: Int?
        let sourceContextFitJSON: String?
        let sourceContextMeasurementRequestedAt: Date?
        let automaticSourceResearchStateRaw: String?
        let automaticSourceResearchInputFingerprint: String?
        let sourcesCuratedAt: Date?
        let sourceThreadCoverageJSON: String?
        let sourceThreadCount: Int?
        let sourceExemplarCount: Int?
        let styleMatch: Double?
        let stageRaw: String?
        let bodyHTML: String?
        let inlinePhotosJSON: String?
        let pendingInstruction: String?
        let draftingInstruction: String?
        let appliedRuleIDsJSON: String?
        let personalizationJSON: String?
        let modelVersion: String?
        let revisions: [DraftRevision]

        init(message: Message, draft: Draft?) {
            composerQueueOverrideRaw = message.composerQueueOverrideRaw
            requiresReply = message.requiresReply
            messageDraft = message.draft
            self.draft = draft
            draftStatus = draft?.status
            draftMessage = draft?.message
            mailboxDraftAccountID = draft?.mailboxDraftAccountID
            replyText = draft?.replyText
            confidence = draft?.confidence
            citationsJSON = draft?.citationsJSON
            gapsJSON = draft?.gapsJSON
            deliverablesJSON = draft?.deliverablesJSON
            replyAttachmentPathsJSON = draft?.replyAttachmentPathsJSON
            interviewStateJSON = draft?.interviewStateJSON
            decisionResearchOverlayJSON = draft?.decisionResearchOverlayJSON
            decisionHistoryJSON = draft?.decisionHistoryJSON
            sourcesJSON = draft?.sourcesJSON
            sourceContextTokenCount = draft?.sourceContextTokenCount
            sourceContextTokenLimit = draft?.sourceContextTokenLimit
            sourceContextFitJSON = draft?.sourceContextFitJSON
            sourceContextMeasurementRequestedAt = draft?.sourceContextMeasurementRequestedAt
            automaticSourceResearchStateRaw = draft?.automaticSourceResearchStateRaw
            automaticSourceResearchInputFingerprint = draft?.automaticSourceResearchInputFingerprint
            sourcesCuratedAt = draft?.sourcesCuratedAt
            sourceThreadCoverageJSON = draft?.sourceThreadCoverageJSON
            sourceThreadCount = draft?.sourceThreadCount
            sourceExemplarCount = draft?.sourceExemplarCount
            styleMatch = draft?.styleMatch
            stageRaw = draft?.stageRaw
            bodyHTML = draft?.bodyHTML
            inlinePhotosJSON = draft?.inlinePhotosJSON
            pendingInstruction = draft?.pendingInstruction
            draftingInstruction = draft?.draftingInstruction
            appliedRuleIDsJSON = draft?.appliedRuleIDsJSON
            personalizationJSON = draft?.personalizationJSON
            modelVersion = draft?.modelVersion
            revisions = draft?.orderedRevisions ?? []
        }

        func restore(message: Message, context: ModelContext) {
            message.composerQueueOverrideRaw = composerQueueOverrideRaw
            message.requiresReply = requiresReply
            message.draft = messageDraft
            guard let draft,
                  let draftStatus,
                  let replyText,
                  let confidence,
                  let sourceThreadCount,
                  let sourceExemplarCount,
                  let styleMatch
            else { return }
            ComposerDiscardTransaction.reinsertIfDeleted(draft, context: context)
            for revision in revisions {
                ComposerDiscardTransaction.reinsertIfDeleted(revision, context: context)
            }
            draft.status = draftStatus
            draft.message = draftMessage
            draft.mailboxDraftAccountID = mailboxDraftAccountID
            draft.replyText = replyText
            draft.confidence = confidence
            draft.citationsJSON = citationsJSON
            draft.gapsJSON = gapsJSON
            draft.deliverablesJSON = deliverablesJSON
            draft.replyAttachmentPathsJSON = replyAttachmentPathsJSON
            draft.interviewStateJSON = interviewStateJSON
            draft.decisionResearchOverlayJSON = decisionResearchOverlayJSON
            draft.decisionHistoryJSON = decisionHistoryJSON
            draft.sourcesJSON = sourcesJSON
            draft.sourceContextTokenCount = sourceContextTokenCount
            draft.sourceContextTokenLimit = sourceContextTokenLimit
            draft.sourceContextFitJSON = sourceContextFitJSON
            draft.sourceContextMeasurementRequestedAt = sourceContextMeasurementRequestedAt
            draft.automaticSourceResearchStateRaw = automaticSourceResearchStateRaw
            draft.automaticSourceResearchInputFingerprint = automaticSourceResearchInputFingerprint
            draft.sourcesCuratedAt = sourcesCuratedAt
            draft.sourceThreadCoverageJSON = sourceThreadCoverageJSON
            draft.sourceThreadCount = sourceThreadCount
            draft.sourceExemplarCount = sourceExemplarCount
            draft.styleMatch = styleMatch
            draft.stageRaw = stageRaw
            draft.bodyHTML = bodyHTML
            draft.inlinePhotosJSON = inlinePhotosJSON
            draft.pendingInstruction = pendingInstruction
            draft.draftingInstruction = draftingInstruction
            draft.appliedRuleIDsJSON = appliedRuleIDsJSON
            draft.personalizationJSON = personalizationJSON
            draft.modelVersion = modelVersion
            draft.revisions = revisions
            for revision in revisions {
                revision.draft = draft
            }
        }
    }
}
