import Foundation
import SwiftData

public enum TrainingPairRole: String, Codable, Sendable {
    case training
    case validationHoldout
}

public enum TrainingCheckpointLifecycle: String, Codable, Sendable {
    case candidate
    case resumeCandidate
    case promoted
    case rejected
    case quarantined
}

@Model
public final class TrainingPair {
    public var id: UUID
    public var message: Message?
    public var evidence: SentTrainingEvidence?
    public var evidenceRevision: Int = 1
    public var latestPromotedEvidenceRevision: Int?
    public var latestPromotedRunID: UUID?
    public var latestPromotedCheckpointID: UUID?
    public var latestFailedEvidenceRevision: Int?
    public var latestFailedTrainingProfileID: String?
    /// The framed sequence length, in tokens, of the input that last failed
    /// training, when the engine measured it. A length over the writer window
    /// makes the pair a rebuild candidate without tokenizing it again.
    /// Optional for lightweight migration.
    public var latestFailedSequenceTokens: Int?
    /// A run whose epoch was rejected before any epoch of it was promoted
    /// defers the revisions that epoch trained, for one training profile,
    /// without claiming the authored evidence is invalid. Deferral is
    /// temporary: it lapses at `latestDeferredAt` plus
    /// `TrainingOptimizationPolicy.deferralRetryInterval`. Only a manual full
    /// run ignores it. A new revision or profile is eligible immediately.
    public var latestDeferredEvidenceRevision: Int?
    public var latestDeferredTrainingProfileID: String?
    public var latestDeferredAt: Date?

    /// When a promoted checkpoint last incorporated this already-learned pair
    /// as replay ballast in an incremental run. Drives least-recently-replayed
    /// selection so replay rotates through the promoted corpus instead of
    /// re-reading the same pairs. Optional for lightweight migration.
    public var lastReplayedAt: Date?
    public var replyToMessageId: UUID?
    public var promptText: String
    public var completionText: String
    public var correspondentId: UUID?
    public var formality: Double?
    public var familiarity: Double?
    public var createdAt: Date

    /// Relative importance when sampling training batches. Default 1.0 for
    /// corpus-mined pairs. Focus-Mode-confirmed edits start from a higher
    /// baseline (1.0 fully authored, 3.0 an edited model draft) and are then
    /// scaled by `TrainingSignal.magnitudeWeight` — the detected edit
    /// signals' own weights — so a one-word tweak and a five-line rewrite
    /// plus a rejected citation are no longer weighted identically.
    public var sourceWeight: Double

    /// Where this pair came from. "corpus" (default), "focus_edit"
    /// (a user-edited draft confirmed in the Composer), or
    /// "instruction_revision" (a revision-shaped pair teaching how the
    /// user's typed revision instruction maps to the text they accepted).
    /// Audit trail — not used in sampling today.
    public var signalSource: String?

    /// JSON-encoded `[TrainingSignal]` captured at the time of user
    /// confirmation. Nil for corpus-mined pairs.
    public var signalsJSON: String?

    /// The `DraftRevision` an "instruction_revision" pair was built from.
    /// Lets the boot-time format migration rebuild the pair's prompt from
    /// the live revision chain instead of dropping it on a version bump.
    /// Nil for corpus and focus-edit pairs. Optional for lightweight
    /// migration.
    public var sourceRevisionID: UUID?

    /// JSON-encoded `[String]` of authoritative Composer decision lines baked
    /// into this pair's prompt as `[USER DECISIONS]`. Persisted on the pair so prompt rebuilds
    /// (format migrations) can re-emit the section
    /// after the source draft is gone. Nil for corpus pairs and sessions
    /// with no answers. Optional for lightweight migration.
    public var userDecisionsJSON: String?

    /// The user's first-draft guidance baked into this pair's prompt as
    /// `[USER DRAFT GUIDANCE]`, persisted for the same rebuild reason.
    /// Nil when none was typed. Optional for lightweight migration.
    public var draftGuidanceText: String?

    /// The prompt format version this pair was built with. Version 0 means
    /// "pre-versioning". Only `TrainingPromptFormat.current` pairs train; the
    /// pair-preparation job rebuilds older ones in place.
    public var promptFormatVersion: Int = 0

    /// The frozen generation basis (request + brief) the prompt renders from,
    /// so a register change can re-render the prompt without a model call.
    /// Nil on pairs built before the writer task. Optional for migration.
    public var generationBasisJSON: String?

    /// The discovered `StyleRegister` whose six-axis cluster contains this
    /// pair's measured completion. Membership only: the prompt is conditioned
    /// on the pair's own measured axes, so a register change never alters
    /// what the adapter trains on. Optional for lightweight migration.
    public var styleRegisterID: UUID?

    /// `StyleRegister.revision` when membership was last stamped. Nil means
    /// the style worker has not yet visited this pair; a stamp with a nil
    /// `styleRegisterID` means "visited, outside every discovered style".
    /// Optional for lightweight migration.
    public var styleRegisterRevision: Int?

    /// Immutable style decision that conditioned this completion. Explicit
    /// decisions can be linked to a separately persisted preference event.
    public var styleControlSnapshotJSON: String?
    /// The actual completion's six-axis observation and rubric provenance.
    public var measuredStyleScoreJSON: String?
    public var styleScoringFailureCount: Int?
    public var styleScoringRetryAfter: Date?
    public var stylePreferenceEventID: UUID?

    /// Durable routing for send-linked standalone messages, which have no
    /// incoming `replyToMessageId` from which to recover an account or
    /// correspondent. Reply pairs continue deriving these from their incoming
    /// message. Optional for lightweight migration.
    public var styleEvidenceAccountID: UUID?
    public var styleEvidenceCorrespondentAddress: String?

    /// Canonical language id ("en", "ja", …) of the pair's *completion* —
    /// the language the user actually wrote the learned text in. Style
    /// discovery clusters within this language (never the incoming message's
    /// language) so a style only ever describes one output language. Nil for
    /// pairs built before language scoping or when detection failed.
    /// Optional for lightweight migration.
    public var languageID: String?

    /// Stable provenance for send-linked feedback. `sourceEventKey` is the
    /// idempotency key; the outgoing ID also reconciles a later Sent-folder
    /// ingest so Ohia never learns its own unchanged generation as human text.
    public var sourceEventKey: String?
    public var sourceOutboxID: UUID?
    public var sourceMessageIDNormalized: String?

    /// Persistent train/validation assignment. Once a corpus pair is placed
    /// in the validation holdout it never enters an optimizer batch, which
    /// keeps checkpoint comparisons honest across later sessions.
    public var trainingRoleRaw: String?

    public init(promptText: String, completionText: String) {
        self.id = UUID()
        self.promptText = promptText
        self.completionText = completionText
        self.evidenceRevision = 1
        self.promptFormatVersion = TrainingPromptFormat.current
        self.createdAt = Date()
        self.sourceWeight = 1.0
    }

    public var styleControlSnapshot: StyleControlSnapshot? {
        get { StyleControlSnapshot.decodeJSON(styleControlSnapshotJSON) }
        set { styleControlSnapshotJSON = newValue?.jsonString }
    }

    /// True when the prompt was built at the current training format; older
    /// pairs wait for the preparation job to rebuild them.
    public var isTrainablePromptFormat: Bool {
        promptFormatVersion == TrainingPromptFormat.current
    }
}

public extension TrainingPair {
    /// IDs of retained Trash rows used to exclude both direct pair messages
    /// and incoming reply sources from all future optimizer work.
    static func trashedMessageIDs(in context: ModelContext) throws -> Set<UUID> {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.trashedAt != nil }
        )
        return Set(try context.fetch(descriptor).map(\.id))
    }

    func referencesTrashedMessage(in trashedMessageIDs: Set<UUID>) -> Bool {
        message?.isTrashed == true
            || replyToMessageId.map(trashedMessageIDs.contains) == true
    }
}

@Model
public final class TrainingCheckpoint {
    public var id: UUID
    public var stepCount: Int
    public var loss: Double
    public var learningRate: Double
    public var adapterPath: String
    public var corpusCoverage: Double
    public var createdAt: Date

    /// Archived checkpoints have had their adapter file pruned from disk but
    /// remain in SwiftData so the history / loss-curve view still shows them.
    /// Never returned from `CheckpointManager.latestAdapterPath` — never load
    /// an archived checkpoint's adapterPath (the file is gone).
    public var archived: Bool

    /// JSON manifest describing the exact base model, prompt format, and LoRA
    /// shape this adapter belongs to. Nil marks a legacy checkpoint; legacy
    /// rows remain visible as history but are never auto-loaded.
    public var manifestJSON: String?

    /// Candidate adapters are not eligible for inference until validation
    /// promotes them. Rejected and quarantined rows remain as an audit trail.
    public var lifecycleRaw: String?
    public var baselineValidationLoss: Double?
    public var validationLoss: Double?
    public var validationExampleCount: Int?
    public var rejectionReason: String?
    public var parentCheckpointID: UUID?

    public init(stepCount: Int, loss: Double, learningRate: Double, adapterPath: String) {
        self.id = UUID()
        self.stepCount = stepCount
        self.loss = loss
        self.learningRate = learningRate
        self.adapterPath = adapterPath
        self.corpusCoverage = 0.0
        self.createdAt = Date()
        self.archived = false
    }
}
