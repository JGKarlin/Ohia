import Foundation

public enum AccountStatus: String, Codable, Sendable {
    case idle
    case syncing
    case paused
    case error
}

public enum ProcessingStatus: String, Codable, Sendable {
    case pending
    case processing
    case completed
    case failed
}

public enum ParticipantRole: String, Codable, Sendable {
    case from
    case to
    case cc
    case bcc
}

public enum JobType: String, Codable, CaseIterable, Sendable {
    /// Decode-only compatibility residue for legacy local Mail.app seed rows.
    /// The scheduler never seeds new jobs of this type; the runner drains any
    /// stored pending row as a successful no-op.
    case ingest
    case parse
    case triage
    case summarize
    case embed
    /// Resolve one pending semantic-tag observation against the app-wide
    /// canonical vocabulary using the local multilingual BGE embedder.
    case resolveSemanticTags
    case buildTrainingPairs
    case train
    case generateDraft
    /// Compile and persist the complete initial reply-source snapshot for one
    /// resolved Needs Reply message. This remains background work and never
    /// creates a Composer Draft or enters the foreground Composer claim lane.
    case prepareReplySources
    case categoryLifecycle
    case sendOutbox
    /// Write Composer draft state to the owning account's IMAP Drafts folder.
    /// Drained by `ComposerDraftSyncWorker`; event-driven from Composer
    /// autosaves/generation/send/discard with a scheduler safety-net reseed.
    case syncComposerDrafts
    case imapBackfill
    case imapPollFolder
    /// Lightweight SELECT-only deletion-watch tick. Runs without fetching
    /// message bodies so server-side deletions can propagate to the
    /// constellation even when full folder polls are on a slower cadence.
    /// Drained by `IMAPDeletionWatchWorker`, which calls
    /// `IMAPSession.runDeletionWatchTick` to issue a SELECT and emit an
    /// `IMAPDeletionEvent` for the existing `DeletionSyncCoordinator`
    /// cascade. No body fetch, no `highestFetchedUID` advance.
    case imapDeletionWatch
    /// Cross-process signal for live inbound IMAP arrivals. This is not a
    /// queue-drained job; it nudges foreground refresh/reconciliation while
    /// user-visible new-mail alerts wait for the row's summary and embedding
    /// to complete.
    case imapLiveInbound
    /// Build k-NN + seed position for one newly-embedded vector.
    /// Enqueued by `PipelineRunner` after every successful `.embed`; drained
    /// by `LayoutIndexWorker`.
    case index
    /// Continuous background force-directed simulation step (whole corpus).
    /// Self-reenqueuing low-priority pacing job drained by `LayoutRefineWorker`.
    case refine
    /// One-shot per-frame force-directed burst. Enqueued when the user
    /// switches to a constellation frame that has no persisted layout in
    /// `vector_frame_layout`. Drained by `FrameBurstWorker`.
    case frameBurst
    /// Periodic density-based clustering over the current frame's settled
    /// positions. Seeded by `BackgroundScheduler.ensurePipelineJobsExist` once
    /// at least `minPoints` vectors are placed; the worker self-reenqueues
    /// every ~5 minutes via `enqueueDeferred` so labels stay fresh.
    case clusterDetect
    /// Walk correspondent and attachment rows, promote first-class entity
    /// sidecars, and enqueue `.entityEmbed` / `.entityRefresh` work.
    case entityPromote
    /// Embed one `Entity` row into the shared vectors table.
    case entityEmbed
    /// Delete and re-embed one existing entity vector after profile drift.
    case entityRefresh
    /// Periodic pass over `PendingDeletionCandidate` rows. Cascades
    /// expired candidates whose Message-ID is still unique (still gone),
    /// and drops candidates whose Message-ID now appears in another folder
    /// (move detected late). Drained by `PendingDeletionReaperWorker`.
    case pendingDeletionReaper
    /// Periodic drift repair between SQLite vectors table and the USearch
    /// ANN index. Drained by `PipelineRunner` through `VectorIndexReconciler`.
    /// Self-reenqueues every 6 hours.
    case reconcileVectorIndex
    /// Re-embeds messages whose vectors carry a non-current
    /// embedding_version. Drained by `PipelineRunner` through
    /// `EmbeddingMigrationCoordinator`; self-reenqueues while stale rows
    /// remain.
    case reindexEmbeddings
    /// Run heavyweight document text extraction (LiteParse PDF, OOXML,
    /// AppKit fallbacks) for one message whose first-run extraction
    /// was bounded.
    /// The worker writes `Attachment.extractedTextPath` for every text-bearing
    /// attachment that was previously skipped, then deletes the message's
    /// existing vectors and flips `embeddingStatus` back to `.pending` so the
    /// regular `.embed` pass re-embeds the body, entities, and the newly-
    /// extracted attachment chunks together.
    case extractAttachments
    /// Run Apple Vision + Apple Foundation Models over image attachments and
    /// persist short grounded visual summaries for later mail summarization.
    /// Drained by `VisualAttachmentExtractionWorker`.
    case extractVisualAttachments
    /// Read capture time, place and captions from photo and video
    /// attachments (including Mail Drop links) and name the place through
    /// MapKit. Drained by `CaptureMetadataWorker`.
    case extractCaptureMetadata
    /// Generate the locked-node attachment-pane paragraph for extracted
    /// document evidence and image visual summaries. Runs after attachment
    /// extraction so panes can open with summaries already persisted instead
    /// of needing first-expand generation.
    case summarizeAttachments
    /// Quiet Qwen-owned account-memory refresh. Runs only while the pipeline
    /// is otherwise calm, refines per-message discourse memory in small
    /// resumable batches, projects account-level `AccountMemory` rows, and
    /// exports the generated `memories.md` context file.
    case accountMemoryRefresh
    /// Deterministic authored bilingual-evidence discovery. This is a
    /// retrieval-worker job and never loads or calls a generative model.
    case translationGlossaryRefresh
    /// User-initiated mutation against a remote mailbox (set/clear \Seen,
    /// set/clear \Flagged, move to Trash, move to Inbox, or explicit
    /// permanent delete from a context menu / Withheld). Drained by
    /// `MailboxMutationWorker`, which routes each queued `MailboxMutation` row
    /// through the per-account `IMAPSession`. Local SwiftData state is updated
    /// optimistically at enqueue time; the server-side write follows on the
    /// worker tick.
    case mailboxMutation
    /// Account-specific, opt-in cleanup of withheld folders. Drained by
    /// `WithheldAutoDeleteWorker`, which permanently deletes old Junk/Trash
    /// messages from the IMAP server according to the account's retention
    /// schedule.
    case withheldAutoDelete
    /// Generate the LLM definition for user-created custom mail categories
    /// that reached their example-tagging threshold, then flip them to
    /// `.active`. Enqueued when the user tags the threshold-reaching example
    /// and reseeded by `BackgroundScheduler.ensurePipelineJobsExist`; drained
    /// by `CustomCategoryDefinitionWorker` via `PipelineRunner`.
    case customCategoryDefinition
    /// Distill dimension-indexed drafting rules from a sent Composer draft:
    /// the model's first draft vs the user's final sent text, plus the user's
    /// answers to the clarifying questions, become add / reinforce / weaken /
    /// delete operations against `DraftingRule` rows. Enqueued by
    /// `SendDispatcher.enqueueSend` at confirm time; drained by
    /// `DraftingRuleWorker` via `PipelineRunner`.
    case generateDraftingRules
    /// Distill emergent `StyleRegister` rows from the training-pair corpus:
    /// stratify sent replies by relationship × classification facet × language, merge
    /// strata by style-vector proximity, have the generative model name and
    /// describe each register, stamp member pairs, and invalidate pairs whose
    /// `Register:` conditioning line went stale. Reseeded by
    /// `BackgroundScheduler.ensurePipelineJobsExist` while unstamped pairs
    /// remain; drained by `StyleRegisterWorker` via `PipelineRunner`.
    case distillStyleRegisters
}

public enum MailboxMutationKind: String, Codable, Sendable {
    case setSeen
    case clearSeen
    case setFlagged
    case clearFlagged
    case delete
    case moveToTrash
    case moveToJunk
    case moveToInbox
}

public enum MailboxMutationStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public enum JobStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
}

public enum CategoryStatus: String, Codable, Sendable {
    case candidate
    case active
    case deprecated
}

public enum VectorCollection: String, Codable, Sendable, CaseIterable {
    case context
    case style
    case attachment
    /// Flat-ontology actor vectors: correspondents, attachment documents,
    /// and later project/topic/team/thread actors. `entityKind` on the
    /// vector row discriminates within this collection.
    case entity
}

public enum EntityKind: String, Codable, Sendable, CaseIterable {
    case correspondent
    case attachment
}

public enum SMTPSecurity: String, Codable, Sendable {
    case tls
    case starttls
    case none
}

public enum SMTPAuthMethod: String, Codable, Sendable {
    case password
    case oauth2
}

public enum IMAPSecurity: String, Codable, Sendable {
    /// Unencrypted TCP — only used in tests against local listeners; not
    /// offered to users in the real provider registry.
    case plaintext
    case tls
    case starttls
}

public enum IMAPAuthMethod: String, Codable, Sendable {
    case password
    case oauth2
}

public enum OutboxStatus: String, Codable, Sendable {
    case queued
    case sending
    case sent
    case failed
    case cancelled
}

public enum DraftStatus: String, Codable, Sendable {
    case pending
    case confirmed
    case sent
    case rejected
    case discarded
}

public enum DraftKind: String, Codable, Sendable {
    case replyToMessage
    case userCompose
}

public enum MessageType: String, Codable, Sendable, CaseIterable {
    case actionable
    case report
    case subscription
    case receipt
    case confirmation
    case unclassified
}
