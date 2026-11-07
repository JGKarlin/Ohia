// Ohia/Composer/ComposerSession.swift
// Per-message state for one Composer drafting session: the step flow
// (decisions → draft), the user's in-progress answers, the rich editor
// content, and the version history. All persistence goes through the
// SwiftData Draft row; the session is a view-model projection of it.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaML
import OhiaScheduler

/// Which step of the Composer flow is on screen for the selected message.
enum ComposerStep: Equatable {
    case decisions
    case draft
}

enum ComposerRecipientCommitResult: Equatable {
    case valid
    case invalid
    case persistenceFailed

    func requireValidForLeaving() throws {
        switch self {
        case .valid: return
        case .invalid: throw ComposerEditorFlushError.invalidRecipients
        case .persistenceFailed: throw ComposerEditorFlushError.persistenceFailed
        }
    }
}

enum ComposerEditorFlushError: LocalizedError {
    case invalidRecipients
    case persistenceFailed
    case richTextExportFailed
    case settledDraft

    var errorDescription: String? {
        switch self {
        case .invalidRecipients: "Correct or remove the invalid recipient addresses before leaving this draft."
        case .persistenceFailed: "The draft could not be saved. Your edits remain in the editor."
        case .richTextExportFailed: "The formatted draft could not be saved. Your edits remain in the editor."
        case .settledDraft: "This draft is no longer available for editing. Your unsaved text remains in the editor."
        }
    }
}

struct TerminationRecipientProjection {
    let outcome: ComposerRecipientCommitResult
    let didChangeDraft: Bool

    fileprivate let toChips: [ComposeAddressEncoding.ParsedAddress]
    fileprivate let ccChips: [ComposeAddressEncoding.ParsedAddress]
    fileprivate let bccChips: [ComposeAddressEncoding.ParsedAddress]
    fileprivate let invalidTo: [String]
    fileprivate let invalidCc: [String]
    fileprivate let invalidBcc: [String]
    fileprivate let toInput: String
    fileprivate let ccInput: String
    fileprivate let bccInput: String
    fileprivate let mode: ReplyRecipientMode
    fileprivate let signature: String
    fileprivate let invalidatesInterviewState: Bool
}

enum ComposerReplyQuotePresentation: Equatable {
    case notApplicable
    case loading
    case ready(String)
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Which face of the Decisions step is on screen, derived from the draft
/// stage and the persisted conditional-interview projection.
/// Shared by the reply (`ComposerSession`) and compose (`ComposeState`) flows.
enum ComposerDecisionsPhase: Equatable {
    /// Sources are compiling, or a compose setup/source edit awaits action.
    case curatingSources
    /// The model is planning or grounding the interview after compilation or
    /// an explicit Re-check.
    case evaluating
    /// One free-text answer is receiving its single bounded repair pass.
    case decidingNext
    /// The current local graph node needs a user answer.
    case answering
    /// Planning completed but the returned graph was invalid.
    case invalid
    /// Ready to draft: either the sources covered the reply outright (no
    /// questions were ever asked) or the interview completed (every asked
    /// question is decided and the model had nothing more to ask).
    case readyToDraft
    /// A draft is being written or exists; Decisions remains available in the rail.
    case drafting
}

/// Two-state projection of a draft's training-influence basis for the Style
/// panel strip. `.base` covers every un-personalized case (base weights,
/// legacy rows, pre-generation); `.personalized` carries the honest basis
/// counts captured at generation time — never a fabricated influence %.
enum PersonalizationDisplay: Equatable {
    case base
    case personalized(
        adapterStep: Int,
        totalPairs: Int,
        correspondentReplies: Int,
        correspondentName: String
    )

    /// Pure projection of a captured snapshot. A nil snapshot (legacy rows or a
    /// not-yet-generated draft) or an inactive adapter maps to `.base`, so the
    /// strip never claims personalization the model didn't actually use.
    static func from(
        snapshot: PersonalizationSnapshot?,
        correspondentName: String
    ) -> PersonalizationDisplay {
        guard let snapshot, snapshot.adapterActive else { return .base }
        return .personalized(
            adapterStep: snapshot.adapterStep,
            totalPairs: snapshot.totalPairsTrained,
            correspondentReplies: snapshot.correspondentReplyCount,
            correspondentName: correspondentName
        )
    }
}

struct ComposerDraftVersion: Identifiable, Equatable {
    let id: UUID
    let index: Int
    let trigger: String
    let instruction: String?
    let createdAt: Date
    let bodyText: String
    let bodyHTML: String?
    let styleRegisterID: UUID?
    let styleControlSnapshot: StyleControlSnapshot?
    let generatedSourcesJSON: String?
    /// The generated revision this version derives from (`DraftRevision.baseRevisionID`).
    var baseRevisionID: UUID? = nil
}

@Observable
final class ComposerSession {
    let messageID: UUID
    let correspondentName: String
    let correspondentEmail: String
    let subject: String

    private(set) var interviewState: ComposerInterviewState?
    /// The current reading language, refreshed on every reload. Unanswered
    /// Draft Questions planned in another language wait for a Re-check.
    private(set) var readingLanguageIdentifier = ComposerQuestionLanguage.current().identifier

    /// The grounding evidence list, decoded from `Draft.sourcesJSON`.
    /// Automatic entries are compiled by the drafting pipeline; user-added
    /// entries are appended by `ComposerSourcesSection`, which writes the
    /// Draft row and calls `reload(from:)`.
    private(set) var sources: [ComposerSource] = []
    private(set) var decisionVersions: [ComposerDecisionVersion] = []
    private(set) var activeDecisionVersionID: UUID?
    private var generatedSourcesJSON: String?
    private(set) var sourceContextTokenCount: Int?
    private(set) var sourceContextTokenLimit: Int?
    /// The current writer-window measurement, from the same measurement as
    /// the token counts; nil while unmeasured or being measured again.
    private(set) var sourceContextUsage: ComposerWriterWindowUsage?
    /// True while the worker owes a measurement of the edited source list.
    private(set) var isMeasuringSourceContext = false
    /// Preparation work lives before the reply Draft row. These flags place
    /// the phase indicator beside the state the worker is actively producing.
    private(set) var showsSourcesLoadingIndicator = false
    private(set) var showsCentralPreparationIndicator = false

    /// File attachments carried by the backing reply draft. Kept separate
    /// from rich-text image attachments, which are body content rather than
    /// `multipart/mixed` deliverables.
    private(set) var attachmentPaths: [String] = []
    private var activeAttachmentImports: Set<ComposerAttachmentImport> = []

    var isImportingAttachments: Bool { !activeAttachmentImports.isEmpty }

    /// Draft-owned inline photos referenced from the rich HTML body. The
    /// bytes live in `ComposerInlinePhotoStore` under this draft's id.
    private(set) var inlinePhotoOwnerID: UUID?
    private(set) var inlinePhotos: [ComposerInlinePhotoAsset] = []
    private var baselineInlinePhotos: [ComposerInlinePhotoAsset] = []
    private var hydratedInlinePhotoOwnerID: UUID?

    /// Generation-time personalization basis, decoded from
    /// `Draft.personalizationJSON`. Nil for legacy rows and drafts that have
    /// not generated yet; `personalizationDisplay` falls back to `.base`.
    private(set) var personalization: PersonalizationSnapshot?

    var step: ComposerStep = .decisions

    /// The backing draft's workflow stage (`DraftStage` raw value), mirrored at
    /// reload. Drives `decisionsPhase` so the decisions step can render the
    /// sources-curation gate, the evaluation wait, the questions, or the
    /// ready-to-draft state without re-deriving from scattered flags.
    private(set) var draftStage: String = DraftStage.collectingSources
    private(set) var isSourceResearchPending = false

    /// Which face of the decisions step is on screen, derived from the stage
    /// and how far the decision interview has progressed.
    var decisionsPhase: ComposerDecisionsPhase {
        if isSourceResearchPending { return .evaluating }
        switch draftStage {
        case DraftStage.collectingSources: return .curatingSources
        case DraftStage.evaluatingSources:
            return interviewProjection?.pendingRepairAnswer == nil ? .evaluating : .decidingNext
        case DraftStage.collectingAnswers:
            if interviewState?.planningOutcome == .invalid { return .invalid }
            return interviewProjection?.currentNode == nil ? .readyToDraft : .answering
        default: return .drafting
        }
    }

    /// The "Decisions" flow-chip subtitle, tracking the current phase.
    var decisionsStepSubtitle: String {
        switch decisionsPhase {
        case .curatingSources: return hasDraftRow ? "review sources" : "preparing sources"
        case .evaluating: return "checking sources"
        case .decidingNext: return "deciding what's next"
        case .answering: return "\(resolvedAnswerCount) decided"
        case .invalid: return "questions unavailable"
        case .readyToDraft: return "ready to draft"
        case .drafting: return "\(resolvedAnswerCount) decided"
        }
    }

    /// Shared AppKit rich-editor content. Plain text derives via
    /// `plainEditorText`; HTML exports via `exportedHTML()`.
    var editorText: NSAttributedString = NSAttributedString(string: "")
    var messageFormat: ComposerMessageFormat = .plainText

    /// The model text the current editing session started from (the live
    /// draft body at load / last reload). Edit detection for the training
    /// diff runs against this.
    private(set) var baselineText: String = ""
    private(set) var baselineEditorContent = NSAttributedString(string: "")
    private(set) var baselineMessageFormat: ComposerMessageFormat = .plainText

    /// Version metadata for the switcher, oldest first.
    private(set) var versions: [ComposerDraftVersion] = []
    /// The version currently shown in the editor (nil = live draft text).
    var viewingVersionIndex: Int?

    /// True while the generation worker owes this draft text (answers
    /// submitted, instruction pending, or regeneration requested).
    private(set) var isAwaitingModel = false
    /// True specifically while a typed Revise instruction is pending —
    /// the narrower reason `ComposerDraftStep` uses to choose the
    /// word-morph revision overlay over the generic dot-on-a-line loader
    /// (which covers every other awaiting reason: first generation,
    /// Regenerate, restyle, source evaluation/research).
    private(set) var isAwaitingInstructionRevision = false
    /// What the model is currently doing, for the progress line.
    private(set) var awaitingReason: String = ""
    /// True when the draft is parked until retrieval prepares generation
    /// context, not actively decoding in Qwen.
    private(set) var isPreparingGenerationContext = false
    /// True when generation is paused after a context-prep timeout or model
    /// failure backoff. The header action can retry because user actions clear
    /// the backoff fields.
    private(set) var isGenerationBlocked = false
    private(set) var generationBlockedReason = ""

    var instructionText: String = ""
    var draftingInstructionText: String = ""
    /// The current question's typed or picked answer, not yet submitted.
    var pendingAnswerDraft = ComposerPendingAnswerDraft()
    /// Asynchronous source additions still running (see `ComposerSourceHost`).
    var inFlightSourceAdditionCount = 0
    /// The writer-window overflow measurement already warned about.
    var warnedWriterOverflowFingerprint: String?
    /// The draft whose one-shot guidance has been projected into the editor.
    /// Poll reloads must not clear or overwrite the user's in-session edits
    /// after generation consumes `Draft.draftingInstruction`.
    private var draftingInstructionDraftID: UUID?

    var citations: [Citation] = []
    var annotations: [SourceAnnotation] = []
    var sourceNeighbors: [NeighborData] = []
    /// The Style panel's register card + picker, computed by the hosting
    /// view (it owns the model context) and equality-guarded on refresh.
    private(set) var stylePanel: StyleRegisterPanelModel = .empty
    private var liveStylePanel: StyleRegisterPanelModel = .empty
    /// Recipient-facing quote state. The prepared content is persisted on the
    /// Draft and frozen into the Outbox before delivery; this projection only
    /// drives the explicit Composer control.
    private(set) var replyQuotePresentation: ComposerReplyQuotePresentation = .loading
    private(set) var includesQuotedOriginal = true
    private var isPreparingReplyQuote = false

    var trainingSignals: [TrainingSignal] = []
    var showDiffAnalysis = false

    /// View-model projection of the draft's `PersonalizationSnapshot` for the
    /// Style panel's training-influence strip. Falls back to `.base` whenever
    /// no trained adapter shaped the draft (base weights, legacy rows, or a
    /// not-yet-generated draft) so the strip never over-claims personalization.
    var personalizationDisplay: PersonalizationDisplay {
        PersonalizationDisplay.from(
            snapshot: personalization,
            correspondentName: correspondentName
        )
    }

    var hasEdits: Bool {
        !editorText.isEqual(to: baselineEditorContent)
            || messageFormat != baselineMessageFormat
            || inlinePhotos != baselineInlinePhotos
            || pendingHistoricalVersion != nil
    }

    var hasPendingChangesToSave: Bool {
        editorPersistenceProjection(adoptingViewedVersion: false).hasEdits
            || hasPendingRecipientChanges
    }

    private var hasPendingRecipientChanges: Bool {
        !toInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !ccInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bccInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !invalidTo.isEmpty || !invalidCc.isEmpty || !invalidBcc.isEmpty
            || Self.replyRecipientSignature(
                mode: replyRecipientMode,
                to: toChips.map(\.asciiAddress),
                cc: ccChips.map(\.asciiAddress),
                bcc: bccChips.map(\.asciiAddress)
            ) != replyRecipientStateSignature
    }

    var hasTextEdits: Bool {
        plainEditorText != baselineText
    }

    /// True while a Send press should surface the training-signal review
    /// step rather than sending: the user hand-edited the model's text and
    /// hasn't confirmed those edits yet.
    var sendNeedsConfirmationFirst: Bool {
        hasTextEdits && !showDiffAnalysis
    }

    var plainEditorText: String {
        ComposerRichTextCodec.plainBodyProjection(of: editorText)
    }

    var toInput: String = ""
    var ccInput: String = ""
    var bccInput: String = ""

    var toChips: [ComposeAddressEncoding.ParsedAddress] = []
    var ccChips: [ComposeAddressEncoding.ParsedAddress] = []
    var bccChips: [ComposeAddressEncoding.ParsedAddress] = []

    var invalidTo: [String] = []
    var invalidCc: [String] = []
    var invalidBcc: [String] = []

    private(set) var recipientSuggestions: [ComposeRecipientSuggestion] = []
    private var replyRecipientStateSignature = ""
    private(set) var replyRecipientMode: ReplyRecipientMode = .reply
    private(set) var canReplyAll = false
    private(set) var replyAllRecipientCount = 0

    var hasAdditionalReplyRecipients: Bool {
        !ccChips.isEmpty || !bccChips.isEmpty
    }

    init(message: Message) {
        self.messageID = message.id
        self.correspondentName = message.fromName ?? message.fromAddress
        self.correspondentEmail = message.fromAddress
        self.subject = message.subject
        reload(from: message)
    }

    /// True once a Draft row exists for the message. Before that, the
    /// pipeline is still preparing the clarifying questions.
    private(set) var hasDraftRow = false
    private(set) var hasPendingStyleControlDecision = false

    // MARK: - Signature slots

    /// The resolved slot backing the draft's signature tail (nil =
    /// unsigned) and the From account's slot roster for the signature
    /// picker. Re-projected on every reload; the roster is
    /// equality-guarded so the 2.5s poll tick doesn't churn the picker.
    private(set) var resolvedSignatureSlotID: UUID?
    private(set) var accountSignatureSlots: [SignatureSlot] = []
    /// Sentinel-coding context for the editor: which slot's images may
    /// legitimately appear in the body as attachments.
    private var signatureOwnerID: UUID?
    private var signatureAssets: [SignatureImageAsset] = []

    /// Re-points the sentinel-coding context after a picker or identity
    /// change (the caller swaps the tail and rebases).
    func updateSignatureContext(slot: SignatureSlot?) {
        resolvedSignatureSlotID = slot?.id
        signatureOwnerID = slot?.id
        signatureAssets = slot?.images ?? []
    }

    /// Re-projects the session from the store row. Called on load and every
    /// time the background worker may have written (poll tick). Preserves
    /// in-progress UI state (instruction box, unsaved answer selections)
    /// and only rebases the editor when the model produced new text.
    func reload(from message: Message) {
        let readingLanguage = ComposerQuestionLanguage.current().identifier
        if readingLanguage != readingLanguageIdentifier {
            readingLanguageIdentifier = readingLanguage
        }
        guard let draft = message.draft else {
            syncReplyRecipientState(from: message, draft: nil)
            let preparation = message.replySourcePreparation
            let preparationStatus = preparation?.statusRaw
            let compiledSources = ComposerSourceCoding.decode(preparation?.sourcesJSON)
            hasDraftRow = false
            hasPendingStyleControlDecision = false
            showsSourcesLoadingIndicator = preparationStatus == ReplySourcePreparationStatus.pending
                || preparationStatus == ReplySourcePreparationStatus.compilingSources
            showsCentralPreparationIndicator = preparationStatus == ReplySourcePreparationStatus.formulatingQuestions
                || preparationStatus == ReplySourcePreparationStatus.drafting
            let preparationRetryWaiting = preparationStatus == ReplySourcePreparationStatus.retryWaiting
            let preparationFailed = preparationStatus == ReplySourcePreparationStatus.failed
            isGenerationBlocked = preparationRetryWaiting || preparationFailed
            generationBlockedReason = preparationRetryWaiting
                ? "Source preparation failed. Retrying automatically."
                : (preparationFailed ? "Source preparation failed." : "")
            isAwaitingModel = !isGenerationBlocked && showsCentralPreparationIndicator
            awaitingReason = isGenerationBlocked
                ? generationBlockedReason
                : (preparationStatus == ReplySourcePreparationStatus.formulatingQuestions
                ? "formulating questions"
                : (preparationStatus == ReplySourcePreparationStatus.drafting ? "writing draft" : ""))
            isAwaitingInstructionRevision = false
            isPreparingGenerationContext = false
            sources = compiledSources
            decisionVersions = []
            activeDecisionVersionID = nil
            generatedSourcesJSON = nil
            // A preparation measured before the writer window existed has no
            // writer meter; it is measured again once a Draft adopts it.
            let measuredForWriter = preparation?.sourceContextTokenLimit == ComposerWriterWindow.promptBudget
            sourceContextTokenCount = measuredForWriter
                ? ComposerWriterWindowUsage.currentCount(preparation?.sourceContextTokenCount,
                    fitJSON: preparation?.sourceContextFitJSON)
                : nil
            sourceContextTokenLimit = measuredForWriter ? preparation?.sourceContextTokenLimit : nil
            if isMeasuringSourceContext { isMeasuringSourceContext = false }
            updateSourceContextUsage(measuredForWriter && preparation?.sourceContextTokenCount != nil
                ? preparation?.sourceContextFitJSON : nil)
            attachmentPaths = []
            inlinePhotoOwnerID = nil
            inlinePhotos = []
            baselineInlinePhotos = []
            personalization = nil
            draftStage = preparationStatus == ReplySourcePreparationStatus.formulatingQuestions
                ? DraftStage.evaluatingSources
                : (preparationStatus == ReplySourcePreparationStatus.drafting
                    ? DraftStage.generating
                    : DraftStage.collectingSources)
            isSourceResearchPending = preparationStatus == ReplySourcePreparationStatus.formulatingQuestions
            interviewState = ComposerInterviewStateCoding.decode(preparation?.interviewStateJSON)
            resolvedSignatureSlotID = nil
            signatureOwnerID = nil
            signatureAssets = []
            replyQuotePresentation = .loading
            includesQuotedOriginal = true
            isPreparingReplyQuote = false
            return
        }
        hasDraftRow = true
        showsSourcesLoadingIndicator = false
        showsCentralPreparationIndicator = false
        if let context = message.modelContext {
            ComposerSourceContextMeasurementScheduler.requestIfNeeded(
                draft: draft,
                context: context
            )
        }
        hasPendingStyleControlDecision = draft.hasPendingStyleControlDecision
        syncReplyRecipientState(from: message, draft: draft)
        inlinePhotoOwnerID = draft.id
        includesQuotedOriginal = draft.resolvedIncludesQuotedOriginal
        if draft.hasPreparedQuotedOriginal,
           let quoted = draft.quotedReplyPlainText {
            replyQuotePresentation = .ready(quoted)
            isPreparingReplyQuote = false
        } else if replyQuotePresentation.isReady {
            replyQuotePresentation = .loading
            isPreparingReplyQuote = false
        }

        let hadUnsavedEdits = editorPersistenceProjection(adoptingViewedVersion: false).hasEdits
        let decodedInlinePhotos = reconcileInlinePhotosOnFirstHydration(
            draft: draft,
            context: message.modelContext
        )
        let inlinePhotosMoved = decodedInlinePhotos != baselineInlinePhotos
        if !hadUnsavedEdits {
            inlinePhotos = decodedInlinePhotos
        }

        // Signature context must resolve before any editor rebase below so
        // the import is sentinel-aware for image-bearing slots.
        let signatureSlot = SignatureSlotResolver.slot(for: draft, account: message.account)
        resolvedSignatureSlotID = signatureSlot?.id
        signatureOwnerID = signatureSlot?.id
        signatureAssets = signatureSlot?.images ?? []
        let slotRoster = message.account?.orderedSignatureSlots ?? []
        if slotRoster.map(\.id) != accountSignatureSlots.map(\.id) {
            accountSignatureSlots = slotRoster
        }
        draftStage = draft.resolvedStage
        isSourceResearchPending = draft.isAutomaticSourceResearchPending

        let decoder = JSONDecoder()
        let decodedInterviewState = ComposerInterviewStateCoding.decode(
            draft.interviewStateJSON
        )
        if decodedInterviewState != interviewState {
            interviewState = decodedInterviewState
        }

        let decodedSources = ComposerSourceCoding.decode(draft.sourcesJSON)
        let decisionHistory = ComposerDecisionHistoryPersistence.decode(
            draft.decisionHistoryJSON
        )
        if decisionHistory?.versions != decisionVersions {
            decisionVersions = decisionHistory?.versions ?? []
        }
        activeDecisionVersionID = decisionHistory?.activeVersionID
        generatedSourcesJSON = draft.generatedSourcesJSON
        // A count whose fit detail does not decode is measured again; until
        // then it is not shown.
        sourceContextTokenCount = ComposerWriterWindowUsage.currentCount(draft.sourceContextTokenCount,
            fitJSON: draft.sourceContextFitJSON)
        sourceContextTokenLimit = draft.sourceContextTokenLimit
        let measuring = draft.sourceContextMeasurementRequestedAt != nil
        if measuring != isMeasuringSourceContext { isMeasuringSourceContext = measuring }
        // Left-out marks belong to the current count; while the edited list
        // is being measured they wait for it.
        updateSourceContextUsage(draft.sourceContextTokenCount == nil ? nil : draft.sourceContextFitJSON)
        // Equality-guarded so the 2.5s poll tick doesn't re-render the Style
        // panel's PersonalizationStrip when the snapshot is unchanged.
        let decodedPersonalization = Self.decodePersonalization(draft.personalizationJSON, decoder: decoder)
        if decodedPersonalization != personalization {
            personalization = decodedPersonalization
        }

        // Equality-guarded so the 2.5s poll tick doesn't invalidate the
        // sources list when nothing changed.
        if decodedSources != sources {
            sources = decodedSources
        }

        let decodedAttachmentPaths = ComposeAddressEncoding.decode(draft.replyAttachmentPathsJSON)
        if decodedAttachmentPaths != attachmentPaths {
            attachmentPaths = decodedAttachmentPaths
        }

        versions = draft.orderedRevisions.map { revision in
            ComposerDraftVersion(
                id: revision.id,
                index: revision.index,
                trigger: revision.triggerRaw,
                instruction: revision.instruction,
                createdAt: revision.createdAt,
                bodyText: revision.bodyText,
                bodyHTML: revision.bodyHTML,
                styleRegisterID: revision.styleRegisterID,
                styleControlSnapshot: revision.styleControlSnapshot,
                generatedSourcesJSON: revision.generatedSourcesJSON,
                baseRevisionID: revision.baseRevisionID
            )
        }
        if draftingInstructionDraftID != draft.id {
            draftingInstructionText = Self.restoredDraftingInstruction(from: draft)
            draftingInstructionDraftID = draft.id
        }

        let waitingForInstruction = draft.pendingInstruction?.isEmpty == false
        // A pending register switch only awaits the model once a generated
        // body exists to rewrite (at least one revision); before first
        // generation it merely steers that pass.
        let waitingForRestyle = draft.pendingStyleRegisterID != nil
            && (draft.revisions ?? []).isEmpty == false
        let waitingForEvaluation = draft.resolvedStage == DraftStage.evaluatingSources
        let waitingForGeneration = draft.resolvedStage == DraftStage.generating
        let waitingForResearch = draft.isAutomaticSourceResearchPending
        let now = Date()
        let waitingForContext = DraftGenerationOrchestrator.isWaitingForContextPack(draft, now: now)
        let contextWaitTimedOut = DraftGenerationOrchestrator.hasContextPackWaitTimedOut(draft, now: now)
        let failureBackoffActive = draft.generationFailureCount != nil
            && (draft.nextGenerationAttemptAt ?? .distantPast) > now
        isPreparingGenerationContext = waitingForContext
        isGenerationBlocked = contextWaitTimedOut || failureBackoffActive
        generationBlockedReason = ComposerGenerationTaskPresentation.generationBlockedReason(draft, now: now)
        isAwaitingModel = !isGenerationBlocked
            && (waitingForInstruction || waitingForRestyle
                || waitingForEvaluation || waitingForResearch
                || waitingForGeneration)
        // Regenerate reuses this same pipeline by stamping pendingInstruction
        // with a synthesized sentinel (DraftGenerationOrchestrator
        // .regenerationInstruction) rather than a typed instruction — it must
        // NOT count as an instruction revision, or Regenerate would wrongly
        // trigger the word-morph overlay instead of the generic loader.
        isAwaitingInstructionRevision = waitingForInstruction
            && draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
                != DraftGenerationOrchestrator.regenerationInstruction
        awaitingReason = isGenerationBlocked
            ? generationBlockedReason
            : (waitingForResearch
                ? "compiling sources"
                : (waitingForInstruction
                ? (ComposerGenerationTaskPresentation.isApplyingStyleAdjustments(
                    pendingInstruction: draft.pendingInstruction,
                    hasPendingStyleAdjustment: draft.hasPendingStyleControlDecision,
                    isGenerationBlocked: isGenerationBlocked
                )
                    ? ComposerGenerationTaskPresentation.applyingStyleAdjustments
                    : "applying your instruction")
                : (waitingForRestyle
                    ? "rewriting in the chosen style"
                    : (waitingForEvaluation
                        ? ComposerQueueItem.WorkState.evaluatingSources.label
                        : (waitingForContext
                            ? "preparing evidence for the draft"
                            : (waitingForGeneration ? "writing draft from your decisions" : ""))))))

        // Rebase whenever a new model/store version lands and the user has no
        // unsaved text, formatting, or per-draft format override on top.
        let storeFormat = draft.resolvedMessageFormat
        let storeMoved = draft.replyText != baselineText
            || draft.bodyHTML != liveBodyHTML
            || storeFormat != baselineMessageFormat
            || inlinePhotosMoved
        if storeMoved, !hadUnsavedEdits {
            setEditorContent(plain: draft.replyText, html: draft.bodyHTML, format: storeFormat)
            // Rich-slot tail upgrade: a body the editor has never produced
            // HTML for (worker-generated text) carries only the slot's
            // plain tail. Swap in the attributed signature once; the
            // exported bodyHTML keeps later reloads idempotent.
            if storeFormat == .richText,
               draft.bodyHTML?.isEmpty ?? true,
               let signatureSlot, signatureSlot.isRich, let slotHTML = signatureSlot.html {
                let signature = SignatureHTMLImageCoding.attributedContent(
                    html: slotHTML,
                    ownerID: signatureSlot.id,
                    assets: signatureSlot.images,
                    store: SignatureAssetStore()
                )
                editorText = ComposerRichTextCodec.swappingSignature(
                    in: editorText,
                    newAttributedSignature: signature
                )
                draft.replyText = ComposerRichTextCodec.plainBodyProjection(of: editorText)
                draft.bodyHTML = exportedHTML()
            }
            baselineText = draft.replyText
            baselineEditorContent = NSAttributedString(attributedString: editorText)
            baselineMessageFormat = storeFormat
            baselineInlinePhotos = inlinePhotos
            liveBodyHTML = draft.bodyHTML
            liveEditorSnapshot = nil
            viewedEditorSnapshot = nil
            pendingHistoricalVersion = nil
            viewingVersionIndex = nil
        }

        citations = Self.decodeCitations(draft.citationsJSON, decoder: decoder)
        rebuildAnnotations()

        switch draft.resolvedStage {
        case DraftStage.collectingSources, DraftStage.evaluatingSources, DraftStage.collectingAnswers:
            // The whole pre-draft flow — curating sources, the evaluation pass,
            // and answering questions — lives on the decisions step.
            step = .decisions
        default:
            // Stay where the user navigated; first load lands on the draft.
            if step == .decisions, !isUserRevisitingDecisions {
                step = .draft
            }
        }
    }

    func beginReplyQuotePreparation(force: Bool) -> Bool {
        guard !isPreparingReplyQuote else { return false }
        if !force {
            switch replyQuotePresentation {
            case .ready, .unavailable:
                return false
            case .notApplicable, .loading:
                break
            }
        }
        isPreparingReplyQuote = true
        replyQuotePresentation = .loading
        return true
    }

    func applyPreparedReplyQuote(_ plainText: String) {
        isPreparingReplyQuote = false
        replyQuotePresentation = .ready(plainText)
    }

    func failReplyQuotePreparation(_ message: String) {
        isPreparingReplyQuote = false
        replyQuotePresentation = .unavailable(message)
    }

    func updateQuotedOriginalInclusion(_ included: Bool) {
        includesQuotedOriginal = included
    }

    private func reconcileInlinePhotosOnFirstHydration(
        draft: Draft,
        context: ModelContext?
    ) -> [ComposerInlinePhotoAsset] {
        let decoded = ComposerInlinePhotoAssetCoding.decode(draft.inlinePhotosJSON)
        guard hydratedInlinePhotoOwnerID != draft.id else { return decoded }
        hydratedInlinePhotoOwnerID = draft.id

        let referenced = ComposerInlinePhotoEncoder.referencedAssets(
            html: draft.bodyHTML,
            ownerID: draft.id,
            assets: decoded
        )
        let previousJSON = draft.inlinePhotosJSON
        let reconciledJSON = ComposerInlinePhotoAssetCoding.encode(referenced)
        if reconciledJSON != previousJSON {
            guard let context else { return decoded }
            draft.inlinePhotosJSON = reconciledJSON
            do {
                try context.save()
            } catch {
                draft.inlinePhotosJSON = previousJSON
                return decoded
            }
        }
        ComposerInlinePhotoStore().prunePhotos(
            ownerID: draft.id,
            keeping: Set(referenced.map(\.id))
        )
        return referenced
    }

    // MARK: - Reply recipients

    @MainActor
    func loadRecipientSuggestions(context: ModelContext) {
        recipientSuggestions = Self.recipientSuggestionCatalog(context: context)
    }

    /// Shared autocomplete catalog for reply and new-message Composer
    /// surfaces. `Correspondent` promotion can legitimately lag ingestion, so
    /// normalized participant rows remain a required fallback. Read those
    /// lightweight rows directly: walking recent messages and faulting every
    /// participant relationship made the first Composer open block the main
    /// actor while SwiftData hydrated the full message graph.
    @MainActor
    static func recipientSuggestionCatalog(context: ModelContext) -> [ComposeRecipientSuggestion] {
        let correspondentRows = (try? context.fetch(FetchDescriptor<Correspondent>())) ?? []
        let correspondentSuggestions = correspondentRows
            .sorted { $0.familiarityScore > $1.familiarityScore }
            .prefix(800)
            .map {
                ComposeRecipientSuggestion(
                    name: $0.primaryName,
                    address: $0.primaryEmail,
                    organization: $0.organization,
                    frequency: $0.messageCount,
                    lastSeen: $0.lastSeenAt
                )
            }
        let knownCorrespondentAddresses = Set(correspondentSuggestions.map {
            Self.normalizedSuggestionAddress($0.address)
        })
        let participantSuggestions = Self.participantBackedRecipientSuggestions(
            context: context,
            excluding: knownCorrespondentAddresses
        )
        let listRows = (try? context.fetch(FetchDescriptor<MailingList>())) ?? []
        let listSuggestions = listRows
            .compactMap { list -> ComposeRecipientSuggestion? in
                guard let address = Self.composeAddress(for: list) else { return nil }
                return ComposeRecipientSuggestion(
                    name: list.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    address: address,
                    organization: list.listId,
                    frequency: list.messageCount,
                    lastSeen: list.lastReceivedAt,
                    kind: .list
                )
            }
            .sorted {
                if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
                return ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast)
            }
            .prefix(400)
        return correspondentSuggestions + participantSuggestions + listSuggestions
    }

    private static func composeAddress(for list: MailingList) -> String? {
        let captured = list.listAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let captured, !captured.isEmpty { return captured }
        let token = list.listId.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.contains("@") ? token : nil
    }

    @MainActor
    private static func participantBackedRecipientSuggestions(
        context: ModelContext,
        excluding excludedAddresses: Set<String>
    ) -> [ComposeRecipientSuggestion] {
        var descriptor = FetchDescriptor<Participant>()
        descriptor.fetchLimit = 5000
        let participants = (try? context.fetch(descriptor)) ?? []
        var accumulators: [String: RecipientSuggestionAccumulator] = [:]

        for participant in participants {
            observeRecipientSuggestion(
                address: participant.emailAddress,
                displayName: participant.displayName,
                date: nil,
                excluding: excludedAddresses,
                accumulators: &accumulators
            )
        }

        return accumulators.values
            .map(\.suggestion)
            .sorted { lhs, rhs in
                if lhs.frequency != rhs.frequency { return lhs.frequency > rhs.frequency }
                let leftSeen = lhs.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                let rightSeen = rhs.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                if leftSeen != rightSeen { return leftSeen > rightSeen }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
            .prefix(800)
            .map { $0 }
    }

    private static func observeRecipientSuggestion(
        address: String,
        displayName: String?,
        date: Date?,
        excluding excludedAddresses: Set<String>,
        accumulators: inout [String: RecipientSuggestionAccumulator]
    ) {
        let normalized = normalizedSuggestionAddress(address)
        guard !normalized.isEmpty, !excludedAddresses.contains(normalized) else { return }
        accumulators[normalized, default: RecipientSuggestionAccumulator(address: normalized)]
            .observe(displayName: displayName, date: date)
    }

    private static func normalizedSuggestionAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @MainActor
    @discardableResult
    func commitTo(context: ModelContext) -> ComposerRecipientCommitResult {
        let result = ComposeAddressEncoding.parseInput(toInput)
        toChips.append(contentsOf: result.valid)
        invalidTo = result.invalid
        toInput = result.invalid.joined(separator: ", ")
        let persisted = persistReplyRecipients(context: context, mode: .custom)
        if !result.invalid.isEmpty { return .invalid }
        return persisted ? .valid : .persistenceFailed
    }

    @MainActor
    @discardableResult
    func commitCc(context: ModelContext) -> ComposerRecipientCommitResult {
        let result = ComposeAddressEncoding.parseInput(ccInput)
        ccChips.append(contentsOf: result.valid)
        invalidCc = result.invalid
        ccInput = result.invalid.joined(separator: ", ")
        let persisted = persistReplyRecipients(context: context, mode: .custom)
        if !result.invalid.isEmpty { return .invalid }
        return persisted ? .valid : .persistenceFailed
    }

    @MainActor
    @discardableResult
    func commitBcc(context: ModelContext) -> ComposerRecipientCommitResult {
        let result = ComposeAddressEncoding.parseInput(bccInput)
        bccChips.append(contentsOf: result.valid)
        invalidBcc = result.invalid
        bccInput = result.invalid.joined(separator: ", ")
        let persisted = persistReplyRecipients(context: context, mode: .custom)
        if !result.invalid.isEmpty { return .invalid }
        return persisted ? .valid : .persistenceFailed
    }

    @MainActor
    func commitAddressBuffers(context: ModelContext) -> ComposerRecipientCommitResult {
        var persistenceFailed = false
        if !toInput.trimmingCharacters(in: .whitespaces).isEmpty {
            persistenceFailed = commitTo(context: context) == .persistenceFailed || persistenceFailed
        }
        if !ccInput.trimmingCharacters(in: .whitespaces).isEmpty {
            persistenceFailed = commitCc(context: context) == .persistenceFailed || persistenceFailed
        }
        if !bccInput.trimmingCharacters(in: .whitespaces).isEmpty {
            persistenceFailed = commitBcc(context: context) == .persistenceFailed || persistenceFailed
        }
        if !invalidTo.isEmpty || !invalidCc.isEmpty || !invalidBcc.isEmpty {
            return .invalid
        }
        if persistenceFailed {
            return .persistenceFailed
        }
        return persistReplyRecipients(context: context) ? .valid : .persistenceFailed
    }

    /// Projects buffered reply recipients onto an already-fetched draft
    /// without saving or changing observable session state. App termination
    /// can therefore commit recipients, editor content, provenance, and the
    /// provider-sync job in one SwiftData transaction.
    @MainActor
    func stageAddressBuffersForTermination(on draft: Draft) -> TerminationRecipientProjection {
        let to = Self.terminationRecipientField(
            input: toInput,
            chips: toChips,
            invalid: invalidTo
        )
        let cc = Self.terminationRecipientField(
            input: ccInput,
            chips: ccChips,
            invalid: invalidCc
        )
        let bcc = Self.terminationRecipientField(
            input: bccInput,
            chips: bccChips,
            invalid: invalidBcc
        )
        let hasBufferedAddress = to.hadBuffer || cc.hadBuffer || bcc.hadBuffer
        let hasChangedChips = Self.replyRecipientSignature(
            mode: replyRecipientMode,
            to: toChips.map(\.asciiAddress),
            cc: ccChips.map(\.asciiAddress),
            bcc: bccChips.map(\.asciiAddress)
        ) != replyRecipientStateSignature
        let mode = hasBufferedAddress || hasChangedChips ? ReplyRecipientMode.custom : replyRecipientMode
        let toJSON = ComposeAddressEncoding.encodePreservingEmpty(to.chips.map(\.asciiAddress))
        let ccJSON = ComposeAddressEncoding.encode(cc.chips.map(\.asciiAddress))
        let bccJSON = ComposeAddressEncoding.encode(bcc.chips.map(\.asciiAddress))
        let signature = Self.replyRecipientSignature(
            mode: mode,
            to: to.chips.map(\.asciiAddress),
            cc: cc.chips.map(\.asciiAddress),
            bcc: bcc.chips.map(\.asciiAddress)
        )
        let didChangeDraft = (hasBufferedAddress || hasChangedChips) && (
            draft.replyToAddressesJSON != toJSON
                || draft.replyCcAddressesJSON != ccJSON
                || draft.replyBccAddressesJSON != bccJSON
                || draft.replyRecipientModeRaw != mode.rawValue
        )

        if didChangeDraft {
            draft.replyToAddressesJSON = toJSON
            draft.replyCcAddressesJSON = ccJSON
            draft.replyBccAddressesJSON = bccJSON
            draft.replyRecipientModeRaw = mode.rawValue
            draft.interviewStateJSON = nil
            draft.decisionResearchOverlayJSON = nil
        }

        return TerminationRecipientProjection(
            outcome: to.invalid.isEmpty && cc.invalid.isEmpty && bcc.invalid.isEmpty
                ? .valid
                : .invalid,
            didChangeDraft: didChangeDraft,
            toChips: to.chips,
            ccChips: cc.chips,
            bccChips: bcc.chips,
            invalidTo: to.invalid,
            invalidCc: cc.invalid,
            invalidBcc: bcc.invalid,
            toInput: to.input,
            ccInput: cc.input,
            bccInput: bcc.input,
            mode: mode,
            signature: signature,
            invalidatesInterviewState: didChangeDraft
        )
    }

    /// Accepts the projection only after the enclosing transaction saves.
    /// A failed save leaves the user's buffered UI state untouched so the
    /// rollback remains authoritative and retryable.
    @MainActor
    func acceptAddressBuffersForTermination(_ projection: TerminationRecipientProjection) {
        toChips = projection.toChips
        ccChips = projection.ccChips
        bccChips = projection.bccChips
        invalidTo = projection.invalidTo
        invalidCc = projection.invalidCc
        invalidBcc = projection.invalidBcc
        toInput = projection.toInput
        ccInput = projection.ccInput
        bccInput = projection.bccInput
        replyRecipientMode = projection.mode
        replyRecipientStateSignature = projection.signature
        if projection.invalidatesInterviewState {
            interviewState = nil
        }
    }

    @MainActor
    func removeToChip(at index: Int, context: ModelContext) {
        guard index < toChips.count else { return }
        toChips.remove(at: index)
        persistReplyRecipients(context: context, mode: .custom)
    }

    @MainActor
    func removeCcChip(at index: Int, context: ModelContext) {
        guard index < ccChips.count else { return }
        ccChips.remove(at: index)
        persistReplyRecipients(context: context, mode: .custom)
    }

    @MainActor
    func removeBccChip(at index: Int, context: ModelContext) {
        guard index < bccChips.count else { return }
        bccChips.remove(at: index)
        persistReplyRecipients(context: context, mode: .custom)
    }

    @MainActor
    func addRecipient(
        _ suggestion: ComposeRecipientSuggestion,
        to field: ComposeRecipientField.Kind,
        context: ModelContext
    ) {
        let parsed = ComposeAddressEncoding.ParsedAddress(
            displayName: suggestion.name,
            asciiAddress: suggestion.address
        )
        switch field {
        case .to:
            if !toChips.contains(where: { $0.asciiAddress.caseInsensitiveCompare(parsed.asciiAddress) == .orderedSame }) {
                toChips.append(parsed)
            }
            toInput = ""
            invalidTo = []
        case .cc:
            if !ccChips.contains(where: { $0.asciiAddress.caseInsensitiveCompare(parsed.asciiAddress) == .orderedSame }) {
                ccChips.append(parsed)
            }
            ccInput = ""
            invalidCc = []
        case .bcc:
            if !bccChips.contains(where: { $0.asciiAddress.caseInsensitiveCompare(parsed.asciiAddress) == .orderedSame }) {
                bccChips.append(parsed)
            }
            bccInput = ""
            invalidBcc = []
        }
        persistReplyRecipients(context: context, mode: .custom)
    }

    @MainActor
    func setReplyRecipientMode(_ mode: ReplyRecipientMode, context: ModelContext) {
        guard mode == .reply || mode == .replyAll else { return }
        let hasBufferedAddress = !toInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !ccInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bccInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasBufferedAddress,
           commitAddressBuffers(context: context) != .valid {
            return
        }
        guard let message = Self.fetchMessage(id: messageID, in: context) else {
            return
        }
        let recipients = ReplyRecipientPolicy.defaultRecipients(for: message, mode: mode)
        applyReplyRecipients(recipients, message: message)
        persistReplyRecipients(context: context, mode: mode)
    }

    private func syncReplyRecipientState(from message: Message, draft: Draft?) {
        let mode = draft?.resolvedReplyRecipientMode ?? .reply
        let defaults = ReplyRecipientPolicy.defaultRecipients(for: message, mode: mode)
        let to = draft?.replyToAddressesJSON.map(ComposeAddressEncoding.decode) ?? defaults.to
        let cc = draft?.replyCcAddressesJSON.map(ComposeAddressEncoding.decode) ?? defaults.cc
        let bcc = draft?.replyBccAddressesJSON.map(ComposeAddressEncoding.decode) ?? defaults.bcc
        let replyAllRecipients = ReplyRecipientPolicy.defaultRecipients(for: message, mode: .replyAll)
        let replyRecipients = ReplyRecipientPolicy.defaultRecipients(for: message, mode: .reply)
        canReplyAll = replyAllRecipients != replyRecipients
        replyAllRecipientCount = replyAllRecipients.recipientCount
        let signature = Self.replyRecipientSignature(mode: mode, to: to, cc: cc, bcc: bcc)
        guard signature != replyRecipientStateSignature else { return }

        replyRecipientMode = mode
        applyReplyRecipients(ReplyRecipientSet(to: to, cc: cc, bcc: bcc), message: message)
        invalidTo = []
        invalidCc = []
        invalidBcc = []
        replyRecipientStateSignature = signature
    }

    private func applyReplyRecipients(_ recipients: ReplyRecipientSet, message: Message) {
        toChips = parsedAddresses(recipients.to, message: message)
        ccChips = parsedAddresses(recipients.cc, message: message)
        bccChips = parsedAddresses(recipients.bcc, message: message)
    }

    private func parsedAddresses(
        _ addresses: [String],
        message: Message
    ) -> [ComposeAddressEncoding.ParsedAddress] {
        addresses.map { address in
            ComposeAddressEncoding.ParsedAddress(
                displayName: displayName(for: address, message: message),
                asciiAddress: address
            )
        }
    }

    private func displayName(for address: String, message: Message) -> String? {
        if address.caseInsensitiveCompare(message.fromAddress) == .orderedSame {
            return message.fromName
        }
        return message.participants.first(where: {
            $0.participant?.emailAddress.caseInsensitiveCompare(address) == .orderedSame
        })?.participant?.displayName
    }

    @MainActor
    @discardableResult
    private func persistReplyRecipients(
        context: ModelContext,
        mode requestedMode: ReplyRecipientMode? = nil
    ) -> Bool {
        let hadDraftRow = hasDraftRow
        guard let draft = backingDraft(in: context) ?? ensureReplyDraftForRecipientEditing(context: context) else {
            return false
        }
        let mode = requestedMode ?? replyRecipientMode
        let to = toChips.map(\.asciiAddress)
        let cc = ccChips.map(\.asciiAddress)
        let bcc = bccChips.map(\.asciiAddress)
        let toJSON = ComposeAddressEncoding.encodePreservingEmpty(to)
        let ccJSON = ComposeAddressEncoding.encode(cc)
        let bccJSON = ComposeAddressEncoding.encode(bcc)
        let signature = Self.replyRecipientSignature(mode: mode, to: to, cc: cc, bcc: bcc)
        guard draft.replyToAddressesJSON != toJSON
            || draft.replyCcAddressesJSON != ccJSON
            || draft.replyBccAddressesJSON != bccJSON
            || draft.replyRecipientModeRaw != mode.rawValue
            || replyRecipientStateSignature != signature else {
            return true
        }
        draft.replyToAddressesJSON = toJSON
        draft.replyCcAddressesJSON = ccJSON
        draft.replyBccAddressesJSON = bccJSON
        draft.replyRecipientModeRaw = mode.rawValue
        ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
        draft.interviewStateJSON = nil
        draft.decisionResearchOverlayJSON = nil
        do {
            try ComposerDraftSyncScheduler.stageDraftSync(draft: draft, context: context)
            try context.save()
            replyRecipientMode = mode
            replyRecipientStateSignature = signature
            interviewState = nil
            if !hadDraftRow, let message = draft.message {
                reload(from: message)
            }
            return true
        } catch {
            context.rollback()
            print("[Ohia] Composer reply recipient save failed: \(String(reflecting: type(of: error)))")
            return false
        }
    }

    @MainActor
    @discardableResult
    private func ensureReplyDraftForRecipientEditing(context: ModelContext) -> Draft? {
        guard let message = Self.fetchMessage(id: messageID, in: context) else { return nil }
        if let existing = message.draft ?? Self.storedDraft(for: message.id, in: context) {
            if message.draft == nil {
                message.draft = existing
            }
            return existing
        }
        // The conversation's reply Draft lives on another email (it moved to
        // the conversation's reply target); never start a second one here.
        guard ReplySourcePreparationEligibility.otherEmailHoldingUnsentReplyDraft(
            for: message,
            context: context
        ) == nil else {
            return nil
        }

        let draft = Draft(
            message: message,
            replyText: "",
            confidence: 0,
            sourceThreadCount: 0,
            sourceExemplarCount: 0,
            styleMatch: 0
        )
        draft.stageRaw = DraftStage.collectingSources
        draft.sourcesJSON = nil
        draft.beginAutomaticSourceResearchIfNeeded()
        draft.fromIdentityID = IdentityResolver.resolveReplyIdentity(message: message)?.id
        draft.signatureSlotID = message.account?.defaultSignatureSlot?.id
        context.insert(draft)
        message.draft = draft
        do {
            try ComposerQueueMembership.stageTargetedDraftJob(
                messageID: message.id,
                context: context
            )
            try context.save()
        } catch {
            print("[Ohia] Composer reply draft preparation failed during recipient edit: \(String(reflecting: type(of: error)))")
        }
        return draft
    }

    private static func replyRecipientSignature(
        mode: ReplyRecipientMode,
        to: [String],
        cc: [String],
        bcc: [String]
    ) -> String {
        [
            mode.rawValue,
            to.map { $0.lowercased() }.joined(separator: ","),
            cc.map { $0.lowercased() }.joined(separator: ","),
            bcc.map { $0.lowercased() }.joined(separator: ",")
        ].joined(separator: "|")
    }

    private struct TerminationRecipientField {
        let chips: [ComposeAddressEncoding.ParsedAddress]
        let invalid: [String]
        let input: String
        let hadBuffer: Bool
    }

    private static func terminationRecipientField(
        input: String,
        chips: [ComposeAddressEncoding.ParsedAddress],
        invalid: [String]
    ) -> TerminationRecipientField {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TerminationRecipientField(
                chips: chips,
                invalid: invalid,
                input: input,
                hadBuffer: false
            )
        }
        let parsed = ComposeAddressEncoding.parseInput(input)
        var projected = chips
        for address in parsed.valid where !projected.contains(where: {
            $0.asciiAddress.caseInsensitiveCompare(address.asciiAddress) == .orderedSame
        }) {
            projected.append(address)
        }
        return TerminationRecipientField(
            chips: projected,
            invalid: parsed.invalid,
            input: parsed.invalid.joined(separator: ", "),
            hadBuffer: true
        )
    }

    // MARK: - Reply attachments

    @MainActor
    func beginAttachmentImport(context: ModelContext) -> ComposerAttachmentImport? {
        guard let draft = backingDraft(in: context), draft.status == .pending else { return nil }
        let attachmentImport = ComposerAttachmentImport(ownerID: draft.id)
        activeAttachmentImports.insert(attachmentImport)
        return attachmentImport
    }

    func finishAttachmentImport(_ attachmentImport: ComposerAttachmentImport) {
        activeAttachmentImports.remove(attachmentImport)
    }

    @MainActor
    func isDraftAssetImportValid(
        _ draftAssetImport: ComposerAttachmentImport,
        context: ModelContext
    ) -> Bool {
        guard activeAttachmentImports.contains(draftAssetImport),
              let draft = backingDraft(in: context)
        else { return false }
        return draft.id == draftAssetImport.ownerID && draft.status == .pending
    }

    @MainActor
    @discardableResult
    func acceptImportedAttachmentPaths(
        _ paths: [String],
        for attachmentImport: ComposerAttachmentImport,
        context: ModelContext
    ) -> Bool {
        guard !Task.isCancelled,
              isDraftAssetImportValid(attachmentImport, context: context)
        else { return false }
        return addAttachmentPaths(paths, context: context)
    }

    @MainActor
    @discardableResult
    func addAttachmentPaths(_ paths: [String], context: ModelContext) -> Bool {
        guard !paths.isEmpty else { return true }
        return persistAttachmentPaths(attachmentPaths + paths, context: context)
    }

    @MainActor
    @discardableResult
    func removeAttachment(
        at index: Int,
        context: ModelContext,
        attachmentStore: ComposerAttachmentStore = ComposerAttachmentStore()
    ) -> Bool {
        guard attachmentPaths.indices.contains(index) else { return false }
        var updated = attachmentPaths
        let removedPath = updated.remove(at: index)
        guard persistAttachmentPaths(updated, context: context) else { return false }
        if let ownerID = inlinePhotoOwnerID {
            attachmentStore.deleteAttachment(atOwnedPath: removedPath, ownerID: ownerID)
        }
        return true
    }

    @MainActor
    private func persistAttachmentPaths(_ paths: [String], context: ModelContext) -> Bool {
        guard let draft = backingDraft(in: context), draft.status == .pending else { return false }
        let encoded = ComposeAddressEncoding.encode(paths)
        guard draft.replyAttachmentPathsJSON != encoded || attachmentPaths != paths else { return true }
        draft.replyAttachmentPathsJSON = encoded
        do {
            try ComposerDraftSyncScheduler.stageDraftSync(draft: draft, context: context)
            try context.save()
            attachmentPaths = paths
            return true
        } catch {
            context.rollback()
            print("[Ohia] Composer reply attachment save failed: \(String(reflecting: type(of: error)))")
            return false
        }
    }

    /// Set when the user deliberately navigated back to the decisions step
    /// from a drafted state, so a poll-tick reload doesn't yank them forward.
    var isUserRevisitingDecisions = false

    // MARK: - Editor content

    func setEditorContent(
        plain: String,
        html: String?,
        format: ComposerMessageFormat
    ) {
        messageFormat = format
        editorText = SignatureHTMLImageCoding.composerContent(
            plainText: plain,
            html: html,
            format: format,
            ownerID: signatureOwnerID ?? UUID(),
            assets: signatureAssets,
            store: SignatureAssetStore(),
            inlinePhotoOwnerID: inlinePhotoOwnerID,
            inlinePhotos: inlinePhotos,
            inlinePhotoStore: ComposerInlinePhotoStore()
        )
    }

    /// Exports a rich draft as HTML (signature image attachments become
    /// `ohia-sig://` tokens). Plain drafts deliberately return nil.
    func exportedHTML() -> String? {
        exportedHTML(for: currentEditorSnapshot)
    }

    func exportedHTML(for snapshot: EditorSnapshot) -> String? {
        SignatureHTMLImageCoding.exportComposerBodyHTML(
            snapshot.content,
            format: snapshot.format,
            ownerID: signatureOwnerID ?? UUID(),
            assets: signatureAssets,
            inlinePhotoOwnerID: inlinePhotoOwnerID,
            inlinePhotos: snapshot.inlinePhotos
        )
    }

    // MARK: - Versions

    /// The live draft's stored HTML, mirrored at reload so returning from a
    /// version view restores formatting.
    private(set) var liveBodyHTML: String?
    /// Snapshot of the editor (including unsaved edits and formatting)
    /// taken when the user navigates away from the live draft to inspect a
    /// version. Restored verbatim by `showLiveDraft`.
    struct EditorSnapshot {
        let content: NSAttributedString
        let format: ComposerMessageFormat
        let inlinePhotos: [ComposerInlinePhotoAsset]

        func matches(_ other: EditorSnapshot) -> Bool {
            content.isEqual(to: other.content)
                && format == other.format
                && inlinePhotos == other.inlinePhotos
        }
    }

    struct EditorPersistenceProjection {
        let snapshot: EditorSnapshot
        let historicalVersion: ComposerDraftVersion?
        let hasEdits: Bool
        let usesVisibleEditor: Bool
    }

    private var liveEditorSnapshot: EditorSnapshot?
    private var viewedEditorSnapshot: EditorSnapshot?
    /// Provenance of edited history adopted into the live buffer before it
    /// has been saved. It travels with that buffer through further browsing.
    private var pendingHistoricalVersion: ComposerDraftVersion?

    var versionForPersistence: ComposerDraftVersion? {
        versions.first(where: { $0.index == viewingVersionIndex }) ?? pendingHistoricalVersion
    }

    private var currentEditorSnapshot: EditorSnapshot {
        EditorSnapshot(content: editorText, format: messageFormat, inlinePhotos: inlinePhotos)
    }

    /// Passive navigation saves the live buffer hidden behind read-only
    /// history. An actual text, format or photo change to that history adopts
    /// the visible version with its provenance when it is persisted.
    func editorPersistenceProjection(adoptingViewedVersion: Bool) -> EditorPersistenceProjection {
        let current = currentEditorSnapshot
        let version = versions.first(where: { $0.index == viewingVersionIndex })
        let editedHistory = viewedEditorSnapshot.map { !current.matches($0) } ?? false
        let usesVisibleEditor = version == nil || adoptingViewedVersion || editedHistory
        let snapshot = usesVisibleEditor ? current : (liveEditorSnapshot ?? current)
        let baseline = EditorSnapshot(
            content: baselineEditorContent,
            format: baselineMessageFormat,
            inlinePhotos: baselineInlinePhotos
        )
        return EditorPersistenceProjection(
            snapshot: snapshot,
            historicalVersion: usesVisibleEditor ? (version ?? pendingHistoricalVersion) : pendingHistoricalVersion,
            hasEdits: !snapshot.matches(baseline) || (usesVisibleEditor && version != nil)
                || pendingHistoricalVersion != nil,
            usesVisibleEditor: usesVisibleEditor
        )
    }

    func acceptPersistedEditorProjection(_ projection: EditorPersistenceProjection, html: String?) {
        let snapshot = projection.snapshot
        let plain = ComposerRichTextCodec.plainBodyProjection(of: snapshot.content)
        if let historicalVersion = projection.historicalVersion {
            generatedSourcesJSON = historicalVersion.generatedSourcesJSON
        }
        if viewingVersionIndex != nil, !projection.usesVisibleEditor {
            baselineText = plain
            baselineEditorContent = NSAttributedString(attributedString: snapshot.content)
            baselineMessageFormat = snapshot.format
            baselineInlinePhotos = snapshot.inlinePhotos
            liveBodyHTML = html
            liveEditorSnapshot = snapshot
            pendingHistoricalVersion = nil
        } else {
            inlinePhotos = snapshot.inlinePhotos
            rebase(plain: plain, html: html, format: snapshot.format)
        }
    }

    func updateStylePanel(_ liveModel: StyleRegisterPanelModel) {
        if let version = pendingHistoricalVersion {
            liveStylePanel = liveModel.displayingVersion(
                styleRegisterID: version.styleRegisterID,
                styleControlSnapshot: version.styleControlSnapshot
            )
        } else {
            liveStylePanel = liveModel
        }
        hasPendingStyleControlDecision = liveStylePanel.isStyleAdjustmentPending
        if let version = versionForPersistence {
            stylePanel = liveModel.displayingVersion(
                styleRegisterID: version.styleRegisterID,
                styleControlSnapshot: version.styleControlSnapshot
            )
        } else {
            stylePanel = liveStylePanel
        }
    }

    func showVersion(_ version: ComposerDraftVersion) {
        adoptEditedHistoryBeforeVersionNavigation()
        if viewingVersionIndex == nil {
            liveEditorSnapshot = currentEditorSnapshot
        }
        viewingVersionIndex = version.index
        stylePanel = liveStylePanel.displayingVersion(
            styleRegisterID: version.styleRegisterID,
            styleControlSnapshot: version.styleControlSnapshot
        )
        messageFormat = version.bodyHTML == nil ? .plainText : .richText
        editorText = SignatureHTMLImageCoding.composerContent(
            plainText: version.bodyText,
            html: version.bodyHTML,
            format: messageFormat,
            ownerID: signatureOwnerID ?? UUID(),
            assets: signatureAssets,
            store: SignatureAssetStore(),
            inlinePhotoOwnerID: inlinePhotoOwnerID,
            inlinePhotos: inlinePhotos,
            inlinePhotoStore: ComposerInlinePhotoStore()
        )
        viewedEditorSnapshot = currentEditorSnapshot
    }

    func showLiveDraft() {
        guard viewingVersionIndex != nil else { return }
        adoptEditedHistoryBeforeVersionNavigation()
        viewingVersionIndex = nil
        stylePanel = liveStylePanel
        if let snapshot = liveEditorSnapshot {
            editorText = NSAttributedString(attributedString: snapshot.content)
            messageFormat = snapshot.format
            inlinePhotos = snapshot.inlinePhotos
        } else {
            setEditorContent(
                plain: baselineText,
                html: liveBodyHTML,
                format: baselineMessageFormat
            )
        }
        liveEditorSnapshot = nil
        viewedEditorSnapshot = nil
    }

    private func adoptEditedHistoryBeforeVersionNavigation() {
        guard let viewedEditorSnapshot,
              let version = versions.first(where: { $0.index == viewingVersionIndex }),
              !currentEditorSnapshot.matches(viewedEditorSnapshot) else { return }
        liveEditorSnapshot = currentEditorSnapshot
        pendingHistoricalVersion = version
        liveStylePanel = stylePanel
    }

    /// Accepts new store content as the editor's baseline (identity swaps,
    /// explicit saves) — clears unsaved-edit state and version viewing.
    func rebase(
        plain: String,
        html: String?,
        format: ComposerMessageFormat? = nil
    ) {
        let resolvedFormat = format ?? messageFormat
        setEditorContent(plain: plain, html: html, format: resolvedFormat)
        baselineText = plain
        baselineEditorContent = NSAttributedString(attributedString: editorText)
        baselineMessageFormat = resolvedFormat
        baselineInlinePhotos = inlinePhotos
        liveBodyHTML = html
        liveEditorSnapshot = nil
        viewedEditorSnapshot = nil
        pendingHistoricalVersion = nil
        viewingVersionIndex = nil
        // Rebasing (Save Draft, Regenerate, Instruction, Restyle, Language
        // change) moves the text the last-confirmed review was computed
        // against — that review is stale, so drop it.
        showDiffAnalysis = false
        trainingSignals = []
    }

    // MARK: - Interview state

    /// Re-check sources restarts the persisted conditional interview.
    func resetInterviewState() {
        interviewState = nil
    }

    // MARK: - Annotations

    func rebuildAnnotations() {
        let text = plainEditorText
        annotations = citations.compactMap { citation in
            guard text.contains(citation.claim) else { return nil }
            return SourceAnnotation(
                originalText: citation.claim,
                sourceLabel: "Source: \(citation.sourceMessageId.prefix(8))",
                sourceMessageID: UUID(uuidString: citation.sourceMessageId),
                color: OhiaColors.chipActiveForeground
            )
        }
    }

    func refreshAnnotationOpacity() {
        let text = plainEditorText
        for i in annotations.indices {
            annotations[i].opacity = text.contains(annotations[i].originalText) ? 1.0 : 0.2
        }
    }

    // MARK: - Decoding

    private static func decodeCitations(_ json: String?, decoder: JSONDecoder) -> [Citation] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let dtos = (try? decoder.decode([CitationDTO].self, from: data)) ?? []
        return dtos.map { Citation(claim: $0.claim, sourceMessageId: $0.sourceMessageId, confidence: 1.0) }
    }

    /// `Draft.draftingInstruction` is a one-shot generation input and is
    /// cleared once the worker records it on the generated revision. Restore
    /// the latest full-generation guidance when a Composer session is opened,
    /// while leaving subsequent poll reloads to preserve in-progress edits.
    private static func restoredDraftingInstruction(from draft: Draft) -> String {
        if let pending = normalizedDraftingInstruction(draft.draftingInstruction) {
            return pending
        }
        for revision in draft.orderedRevisions.reversed()
        where revision.triggerRaw == DraftRevisionTrigger.initial
            || revision.triggerRaw == DraftRevisionTrigger.regenerate {
            return normalizedDraftingInstruction(revision.instruction) ?? ""
        }
        return ""
    }

    private static func normalizedDraftingInstruction(_ instruction: String?) -> String? {
        guard let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func decodePersonalization(
        _ json: String?,
        decoder: JSONDecoder
    ) -> PersonalizationSnapshot? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(PersonalizationSnapshot.self, from: data)
    }

}

private struct RecipientSuggestionAccumulator {
    let address: String
    private(set) var name: String = ""
    private(set) var frequency: Int = 0
    private(set) var lastSeen: Date?

    mutating func observe(displayName: String?, date: Date?) {
        frequency += 1
        let cleanName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if shouldUseName(cleanName) {
            name = cleanName
        }
        if let date, date > (lastSeen ?? .distantPast) {
            lastSeen = date
        }
    }

    var suggestion: ComposeRecipientSuggestion {
        ComposeRecipientSuggestion(
            name: name,
            address: address,
            organization: nil,
            frequency: frequency,
            lastSeen: lastSeen
        )
    }

    private func shouldUseName(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if name.isEmpty { return true }
        if name.caseInsensitiveCompare(address) == .orderedSame { return true }
        if name.contains("@"), !candidate.contains("@") { return true }
        return !candidate.contains("@") && candidate.count > name.count
    }
}

// MARK: - ComposerQuestionRoundsHost

extension ComposerSession: ComposerQuestionRoundsHost {}

extension ComposerSession: ComposerDecisionsHost {
    var hasDraftVersions: Bool { !versions.isEmpty }
    var draftVersionCount: Int { versions.count }
    var draftNoun: String { "reply" }
    var canAdvanceFromSources: Bool { true }
    var showsDraftGuidanceWhileCurating: Bool { false }
    var hasPendingDecisionSourceChanges: Bool {
        if let interviewState,
           interviewState.contractVersion != ComposerInterviewPlanner.contractVersion {
            return true
        }
        // Before the first draft only: once drafted, open questions stay as
        // they are and a Re-check the author chooses re-plans them.
        if hasDraftRow, !hasDraftVersions,
           interviewState?.asksUnansweredQuestion(
               outsideReadingLanguage: readingLanguageIdentifier
           ) == true {
            return true
        }
        let active = activeDecisionVersionID.flatMap { activeID in
            decisionVersions.first(where: { $0.id == activeID })
        } ?? decisionVersions.last
        guard let active else { return false }
        return sources != active.sources
            || active.interviewState.contractVersion != ComposerInterviewPlanner.contractVersion
    }

    var hasPendingDecisionInputChanges: Bool {
        let active = activeDecisionVersionID.flatMap { activeID in
            decisionVersions.first(where: { $0.id == activeID })
        } ?? decisionVersions.last
        guard let active else { return hasPendingDecisionSourceChanges }
        let currentGuidance = draftingInstructionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let evaluatedGuidance = (active.draftGuidance ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hasPendingDecisionSourceChanges || currentGuidance != evaluatedGuidance
    }
}

extension ComposerSession: ComposerDraftEditingHost {
    var hasPendingStyleRegeneration: Bool {
        hasPendingStyleControlDecision
    }
    var hasPendingSourceChanges: Bool {
        ComposerRegenerationInputState.hasPendingSourceChanges(
            currentSources: sources,
            generatedSourcesJSON: displayedGeneratedSourcesJSON
        )
    }
    /// Automatic thread emails in the sources that the displayed version was
    /// not generated from: emails that reached the thread after the draft
    /// was written and were added by the thread-change reconciler.
    var pendingThreadEmailCount: Int {
        guard hasPendingSourceChanges else { return 0 }
        let applied = Set(
            ComposerSourceCoding.decode(displayedGeneratedSourcesJSON)
                .filter { $0.kind == .thread }
                .compactMap(\.messageID)
        )
        return sources
            .filter { $0.kind == .thread && !$0.isUserAdded }
            .compactMap(\.messageID)
            .filter { !applied.contains($0) }
            .count
    }
    private var displayedGeneratedSourcesJSON: String? {
        ComposerRegenerationInputState.displayedGeneratedSourcesJSON(
            liveGeneratedSourcesJSON: pendingHistoricalVersion == nil
                ? generatedSourcesJSON : pendingHistoricalVersion?.generatedSourcesJSON,
            versions: versions,
            viewingVersionIndex: viewingVersionIndex
        )
    }
    var hasPendingRegenerationInputs: Bool {
        hasPendingSourceChanges || hasPendingStyleRegeneration
    }
    var canSendDraft: Bool {
        !isImportingAttachments
            && !hasPendingStyleControlDecision
            && (!includesQuotedOriginal || replyQuotePresentation.isReady)
            && (
            !plainEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ComposerInlinePhotoCoding.containsPhoto(in: editorText)
        )
    }

    func updateEditorContent(_ content: NSAttributedString) {
        // Further edits after a Confirm invalidate the review that was
        // computed against the pre-edit text — re-confirming recomputes it
        // against what's actually about to send.
        if showDiffAnalysis, !content.isEqual(to: editorText) {
            showDiffAnalysis = false
            trainingSignals = []
        }
        editorText = NSAttributedString(attributedString: content)
    }

    func updateMessageFormat(_ format: ComposerMessageFormat) {
        messageFormat = format
    }

    func updateInlinePhotos(_ photos: [ComposerInlinePhotoAsset]) {
        inlinePhotos = photos
    }
}

extension ComposerSession: ComposerRecipientHost {
    var recipientMutationsEnabled: Bool {
        !isAwaitingModel && draftStage != DraftStage.evaluatingSources
    }
    var replyScopeMode: ReplyRecipientMode? { replyRecipientMode }
    var canSelectReplyAll: Bool { canReplyAll }
}

// MARK: - ComposerSourceHost

extension ComposerSession {
    /// Equality-guarded so the poll tick does not invalidate the source rows
    /// when the measurement is unchanged.
    fileprivate func updateSourceContextUsage(_ fitJSON: String?) {
        let usage = ComposerWriterWindowUsage.decode(fitJSON)
        if usage != sourceContextUsage {
            sourceContextUsage = usage
        }
    }
}

extension ComposerSession: ComposerSourceHost {
    /// A reply always has an inbound message and (usually) a thread, so the
    /// Sources Add popover can offer thread siblings and attachments.
    var supportsMessageCandidates: Bool { true }
    var sourceMutationsEnabled: Bool {
        guard hasDraftRow, !isSourceResearchPending else { return false }
        if draftStage == DraftStage.evaluatingSources {
            return isGenerationBlocked
        }
        if draftStage == DraftStage.generating {
            return false
        }
        return !isAwaitingModel
    }

    @MainActor
    func backingDraft(in context: ModelContext) -> Draft? {
        guard let message = Self.fetchMessage(id: messageID, in: context) else { return nil }
        return message.draft ?? Self.storedDraft(for: messageID, in: context)
    }

    @MainActor
    func candidateMessage(in context: ModelContext) -> Message? {
        Self.fetchMessage(id: messageID, in: context)
    }

    @MainActor
    func correspondentAddress(in context: ModelContext) -> String? {
        let address = Self.fetchMessage(id: messageID, in: context)?.fromAddress
        return (address?.isEmpty ?? true) ? nil : address
    }

    @MainActor
    func reloadAfterSourceMutation(in context: ModelContext) {
        guard let message = Self.fetchMessage(id: messageID, in: context) else { return }
        reload(from: message)
    }

    private static func fetchMessage(id: UUID, in context: ModelContext) -> Message? {
        let predicate = #Predicate<Message> { $0.id == id }
        return try? context.fetch(FetchDescriptor<Message>(predicate: predicate)).first
    }

    private static func storedDraft(for messageID: UUID, in context: ModelContext) -> Draft? {
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.message?.id == messageID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

/// Citation underlay annotation, carried over from the retired Focus mode.
struct SourceAnnotation: Identifiable {
    let id: UUID
    let originalText: String
    let sourceLabel: String
    let sourceMessageID: UUID?
    let color: Color
    var opacity: Double = 1.0

    init(
        id: UUID = UUID(),
        originalText: String,
        sourceLabel: String,
        sourceMessageID: UUID? = nil,
        color: Color = OhiaColors.chipActiveForeground,
        opacity: Double = 1.0
    ) {
        self.id = id
        self.originalText = originalText
        self.sourceLabel = sourceLabel
        self.sourceMessageID = sourceMessageID
        self.color = color
        self.opacity = opacity
    }
}
