import Foundation
import SwiftData
import OhiaCore
import OhiaMail
import OhiaML

/// Call only after all mail/model workers have stopped. File cleanup precedes
/// the single SwiftData save: on failure the rows still identify every artifact
/// for retry. No mailbox mutation or trained-checkpoint deletion occurs here.
@MainActor
public struct AccountContentDeletion {
    private let context: ModelContext
    private let layout: OhiaStorageLayout
    private let vectorStore: VectorStore
    private let canonicalStore: CanonicalStore

    public init(context: ModelContext, layout: OhiaStorageLayout,
                vectorStore: VectorStore, canonicalStore: CanonicalStore) {
        self.context = context
        self.layout = layout
        self.vectorStore = vectorStore
        self.canonicalStore = canonicalStore
    }

    @discardableResult
    public func remove(accountID: UUID, removeCredential: (String, String) throws -> Void) throws -> [UUID] {
        try AccountDisconnectionRequest.begin(accountID: accountID, in: layout)
        do {
            let accounts = try context.fetch(FetchDescriptor<Account>())
            guard let account = accounts.first(where: { $0.id == accountID }) else {
                // The last database save succeeded, but removing the marker
                // failed. All destructive work was already completed.
                try AccountDisconnectionRequest.finish(in: layout)
                return []
            }
            let messages = try context.fetch(FetchDescriptor<Message>(predicate: #Predicate {
                $0.accountID == accountID || $0.account?.id == accountID
            }))
            let messageIDs = Set(messages.map(\.id))
            let identityIDs = Set(account.identities.map(\.id))
            let drafts = try context.fetch(FetchDescriptor<Draft>()).filter {
                $0.composeFromAccountID == accountID || $0.mailboxDraftAccountID == accountID
                    || $0.message.map { messageIDs.contains($0.id) } == true
                    || $0.fromIdentityID.map(identityIDs.contains) == true
            }
            let draftIDs = Set(drafts.map(\.id))
            let outbox = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
                $0.account?.id == accountID
                    || $0.draft.map { draftIDs.contains($0.id) } == true
                    || $0.message.map { messageIDs.contains($0.id) } == true
            }
            let outboxIDs = Set(outbox.map(\.id))
            let evidence = try context.fetch(FetchDescriptor<SentTrainingEvidence>()).filter {
                $0.accountID == accountID || $0.sourceMessageID.map(messageIDs.contains) == true
                    || $0.sourceOutboxID.map(outboxIDs.contains) == true
            }
            let evidenceIDs = Set(evidence.map(\.id))
            let pairs = try context.fetch(FetchDescriptor<TrainingPair>()).filter {
                $0.styleEvidenceAccountID == accountID
                    || $0.evidence.map { evidenceIDs.contains($0.id) } == true
                    || $0.message.map { messageIDs.contains($0.id) } == true
                    || $0.replyToMessageId.map(messageIDs.contains) == true
                    || $0.sourceOutboxID.map(outboxIDs.contains) == true
            }
            let pairIDs = Set(pairs.map(\.id))
            let memories = try context.fetch(FetchDescriptor<AccountMemory>()).filter { $0.accountID == accountID }
            let memoryKeys = Set(memories.map(\.memoryKey))

            // Credential references can be shared by incoming/outgoing setup
            // and, exceptionally, another account. Keep references still owned.
            let retainedRefs = Set(accounts.filter { $0.id != accountID }.flatMap(Self.credentialReferences))
            for ref in Set(Self.credentialReferences(account)).subtracting(retainedRefs) {
                for service in [OAuthTokenStore.service, IMAPCredentials.service, SMTPCredentials.service] {
                    try removeCredential(service, ref)
                }
            }

            let clusters = VectorClusterStore(sharedDB: vectorStore.rawHandle, lock: vectorStore.rawLock)
            let cascade = MessageLocalDeletionCascade(
                vectorStore: vectorStore,
                neighborsStore: VectorNeighborsStore(sharedDB: vectorStore.rawHandle, lock: vectorStore.rawLock),
                frameLayoutStore: VectorFrameLayoutStore(sharedDB: vectorStore.rawHandle, lock: vectorStore.rawLock),
                clusterStore: clusters,
                canonicalStore: canonicalStore)
            var affectedFrames: Set<FrameKey> = []
            for id in messageIDs {
                affectedFrames.formUnion(try clusters.framesContaining(messageId: id.uuidString))
            }
            // Persist recomputation before erasing memberships. The durable
            // maintenance barrier prevents these jobs running during cleanup;
            // retries retain the jobs even after membership rows are gone.
            try cascade.enqueueClusterRecomputeIfNeeded(frames: affectedFrames, context: context, jobQueue: JobQueue())
            let fts = try MessageFTSIndex(sharedDB: vectorStore.rawHandle, lock: vectorStore.rawLock)
            for id in messageIDs {
                try fts.forgetMessage(messageId: id.uuidString)
                try cascade.removeLocalArtifacts(messageID: id)
            }
            let attachmentKeys = Set(messages.flatMap { message in
                message.attachments.map { EntityOrchestrator.attachmentKey(filename: $0.filename, parentMessageId: message.id.uuidString) }
            })
            let affectedParticipantIDs = Set(messages.flatMap(\.participants).compactMap { $0.participant?.id })
            let survivingLinks = try context.fetch(FetchDescriptor<MessageParticipant>()).filter {
                $0.message.map { !messageIDs.contains($0.id) } == true
            }
            let remainingByParticipant = Dictionary(grouping: survivingLinks, by: { $0.participant?.id })
            var affectedCorrespondentIDs: Set<UUID> = []
            for participant in try context.fetch(FetchDescriptor<Participant>()) where affectedParticipantIDs.contains(participant.id) {
                if let correspondent = participant.correspondent { affectedCorrespondentIDs.insert(correspondent.id) }
                if remainingByParticipant[participant.id, default: []].isEmpty { context.delete(participant) }
            }
            var affectedCorrespondentKeys: Set<String> = []
            for correspondent in try context.fetch(FetchDescriptor<Correspondent>()) where affectedCorrespondentIDs.contains(correspondent.id) {
                affectedCorrespondentKeys.insert(correspondent.primaryEmail.lowercased())
                let remaining = survivingLinks.filter { $0.participant?.correspondent?.id == correspondent.id }
                if remaining.isEmpty {
                    context.delete(correspondent)
                } else {
                    correspondent.messageCount = Set(remaining.compactMap { $0.message?.id }).count
                    correspondent.firstSeenAt = remaining.compactMap { $0.message?.receivedAt }.min()
                    correspondent.lastSeenAt = remaining.compactMap { $0.message?.receivedAt }.max()
                    correspondent.profileJSON = nil
                }
            }
            for entity in try context.fetch(FetchDescriptor<Entity>()) {
                guard (entity.kind == .attachment && attachmentKeys.contains(entity.key))
                        || (entity.kind == .correspondent && affectedCorrespondentKeys.contains(entity.key)) else { continue }
                try vectorStore.deleteEntityVectors(kind: entity.kind, key: entity.key)
                context.delete(entity)
            }
            for id in draftIDs.union(messageIDs).union(outboxIDs) {
                try removeDirectory(layout.composerAttachments, ownerID: id)
                try removeDirectory(layout.composerInlinePhotos, ownerID: id)
            }
            for slot in account.signatureSlots {
                try removeDirectory(layout.signatureAssets, ownerID: slot.id)
            }
            try removeDirectory(layout.privateRoot.appendingPathComponent("memories"), ownerID: accountID)
            // Shared retrieval/summary packs may quote this account from another
            // account's draft. They are reproducible and must be regenerated.
            try removeIfPresent(layout.cacheData)

            // Styles span accounts, and any discovered style (active, retired
            // or deleted) may have been described from this account's mail
            // at some point. Every model-written description and correspondent
            // list goes now; the next discovery pass re-clusters the surviving
            // sent mail, retires any style it no longer supports, and
            // describes the rest again.
            for style in try context.fetch(FetchDescriptor<StyleRegister>()) where !style.isUserSavedStyle {
                style.summary = StyleRegisterNamer.provisionalSummary(
                    for: style.styleAxes ?? ComposerStyleRubric.neutral, reference: ComposerStyleRubric.neutral,
                    isOnlyStyle: false, memberCount: style.exemplarCount)
                style.correspondents = []
                style.lastDistilledAt = nil
                style.revision += 1
                style.updatedAt = .now
            }
            for row in outbox { context.delete(row) }
            for row in pairs { context.delete(row) }
            for row in evidence { context.delete(row) }
            for row in drafts { context.delete(row) }
            for row in memories { context.delete(row) }
            try delete(AccountMemoryRefreshState.self) { $0.accountID == accountID }
            try delete(StylePreferenceEvent.self) { $0.accountID == accountID }
            try delete(DraftingRule.self) { $0.accountID == accountID }
            let removedTargets = try context.fetch(FetchDescriptor<TrainingCorpusRunTarget>()).filter {
                $0.accountID == accountID || pairIDs.contains($0.pairID) || evidenceIDs.contains($0.evidenceID)
            }
            for target in removedTargets {
                if let run = target.run, run.state != .completed, run.state != .failed {
                    // Interrupted runs are resumable. This snapshot is no
                    // longer valid; let the next run plan the surviving corpus.
                    run.state = .failed
                    run.failedAt = .now
                    run.failureReason = "Account disconnected; training corpus snapshot invalidated."
                }
                context.delete(target)
            }
            try delete(ConversationCurationAction.self) { memoryKeys.contains($0.targetKey) }
            try delete(MailboxMutation.self) { $0.accountID == accountID || messageIDs.contains($0.messageID) }
            try delete(PendingDeletionCandidate.self) { $0.accountID == accountID }
            try delete(MailingListIgnoredMessage.self) { $0.accountID == accountID }
            try delete(MailingListIgnoreRule.self) { $0.accountID == accountID }
            try delete(MailingList.self) { $0.accountID == accountID }
            try delete(MailProjectMembership.self) { messageIDs.contains($0.messageID) }
            try delete(MailProjectDecision.self) { $0.targetKind == .message && messageIDs.contains($0.targetID) }
            try delete(ProjectLensAction.self) { $0.messageId.map(messageIDs.contains) == true }
            let glossaryEvidence = try context.fetch(FetchDescriptor<TranslationGlossaryEvidence>())
            let removedGlossaryEvidence = glossaryEvidence.filter {
                $0.sourceAccountID == accountID || $0.sourceMessageID.map(messageIDs.contains) == true
                    || $0.sourceDraftID.map(draftIDs.contains) == true
            }
            let removedGlossaryIDs = Set(removedGlossaryEvidence.map(\.id))
            let affectedPairs = Set(removedGlossaryEvidence.map(\.pairID))
            let retainedGlossaryPairs = Set(glossaryEvidence.filter { !removedGlossaryIDs.contains($0.id) }.map(\.pairID))
            for row in removedGlossaryEvidence { context.delete(row) }
            try delete(TranslationGlossaryPair.self) { affectedPairs.contains($0.id) && !retainedGlossaryPairs.contains($0.id) }
            let ownedIDs = messageIDs.union(draftIDs).union(outboxIDs).union([accountID])
            try delete(Job.self) { job in
                job.messageId.map(ownedIDs.contains) == true || Self.references(ownedIDs, in: job.payload)
                    || Self.references(ownedIDs, in: job.checkpointData)
            }
            try delete(ReplySourcePreparation.self) {
                messageIDs.contains($0.messageId) || Self.references(messageIDs, in: $0.sourcesJSON)
                    || Self.references(messageIDs, in: $0.witnessedLiveThreadMessageIDsJSON)
            }

            let threadIDs = Set(messages.compactMap { $0.thread?.id })
            let affectedTagIDs = Set(messages.flatMap(\.semanticTagMemberships).map(\.tagID))
                .union(messages.flatMap(\.semanticTagObservations).compactMap(\.resolvedTagID))
            for tag in try context.fetch(FetchDescriptor<SemanticTag>()) where affectedTagIDs.contains(tag.id) {
                if tag.memberships.allSatisfy({ messageIDs.contains($0.messageID) }) { context.delete(tag) }
            }
            for thread in try context.fetch(FetchDescriptor<MessageThread>()) where threadIDs.contains(thread.id) {
                let remaining = thread.messages.filter { !messageIDs.contains($0.id) }
                if remaining.isEmpty {
                    context.delete(thread)
                } else {
                    thread.messageCount = remaining.count
                    thread.firstMessageAt = remaining.compactMap(\.receivedAt).min()
                    thread.lastMessageAt = remaining.compactMap(\.receivedAt).max()
                    thread.participantCount = Set(remaining.flatMap(\.participants).compactMap { $0.participant?.id }).count
                }
            }
            for message in messages { context.delete(message) }
            context.delete(account)
            // Repair and persist the ANN index while the account still exists
            // on disk. A failed index write must not lose retry ownership.
            _ = try vectorStore.reconcileIndexIfAvailable()
            try vectorStore.saveIndexIfAvailable()
            try context.save()
            try AccountDisconnectionRequest.finish(in: layout)
            return Array(messageIDs)
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func credentialReferences(_ account: Account) -> [String] {
        [account.keychainRef, account.imapKeychainRef, account.smtpKeychainRef].compactMap { $0 }
    }

    private func delete<T: PersistentModel>(_ type: T.Type, matching: (T) -> Bool) throws {
        for row in try context.fetch(FetchDescriptor<T>()) where matching(row) { context.delete(row) }
    }

    private func removeDirectory(_ root: URL, ownerID: UUID) throws {
        try removeIfPresent(root.appendingPathComponent(ownerID.uuidString.lowercased(), isDirectory: true))
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func references(_ ids: Set<UUID>, in json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return false }
        func contains(_ value: Any) -> Bool {
            if let string = value as? String, let id = UUID(uuidString: string) { return ids.contains(id) }
            if let array = value as? [Any] { return array.contains(where: contains) }
            if let object = value as? [String: Any] { return object.values.contains(where: contains) }
            return false
        }
        return contains(value)
    }
}
