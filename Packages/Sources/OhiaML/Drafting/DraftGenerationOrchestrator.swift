// DraftGenerationOrchestrator.swift
// Drives the questions-first Composer pipeline over the `.generateDraft`
// job. Three passes per tick, in user-urgency order:
//   1. instruction revisions — drafts whose Composer instruction box left a
//      `pendingInstruction` (the user is actively waiting),
//   2. owed generations — drafts in `DraftStage.generating` (the user
//      answered or skipped the clarifying questions),
//   3. queue intake — actionable messages with analysis but no draft yet:
//      a question-stage draft is created; messages with nothing to ask go
//      straight to generation.
// Wraps DraftOrchestrator, handles persistence (Draft + DraftRevision),
// and derives UI-facing signals (confidence, styleMatch).

import CryptoKit
import Foundation
import SwiftData
import OhiaCore
import os

private let questionGroundingStateSignposter = OSSignposter(
    subsystem: "org.jgkarlin.Ohia",
    category: "questionGroundingState"
)

private let questionPreparationLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "questionPreparation"
)

enum ComposerPublicationTesting {
    @TaskLocal static var beforePublication: (@MainActor @Sendable () -> Void)?
}

public final class DraftGenerationOrchestrator: @unchecked Sendable {

    public typealias AutomaticWebsiteSourceExpander =
        @Sendable ([ComposerSource]) async throws -> [ComposerSource]

    private enum ComposeSourceSelectionError: Error {
        case selectorUnavailable
    }

    private enum QuestionEvaluationOutcome {
        case completed(Draft)
        case stale
        case alreadyInFlight
    }

    private struct QuestionRecipientState: Equatable {
        let replyModeRaw: String?
        let replyToJSON: String?
        let replyCcJSON: String?
        let replyBccJSON: String?
        let composeToJSON: String?
        let composeCcJSON: String?
        let composeBccJSON: String?
    }

    /// Inputs owned by the user must still describe the same request after
    /// inference, including pending slider and picker choices. A superseded
    /// result must never replace the body the user is still editing.
    private struct DraftInputSnapshot: Equatable {
        let values: [String?]
        let pendingStyleControls: String?
        let pendingStyleRegisterID: UUID?

        @MainActor
        init(draft: Draft) {
            let message = draft.message
            values = [
                draft.id.uuidString, draft.kind?.rawValue, draft.status.rawValue,
                draft.stageRaw, draft.languageID, draft.replyText, draft.bodyHTML,
                draft.pendingInstruction, draft.draftingInstruction, draft.composeInstruction,
                draft.sourcesJSON, draft.interviewStateJSON, draft.decisionHistoryJSON,
                draft.decisionResearchOverlayJSON, draft.generatedSourcesJSON,
                draft.replyRecipientModeRaw, draft.replyToAddressesJSON,
                draft.replyCcAddressesJSON, draft.replyBccAddressesJSON,
                draft.composeToJSON, draft.composeCcJSON, draft.composeBccJSON,
                draft.composeSubject, draft.composeFromAccountID?.uuidString,
                draft.fromIdentityID?.uuidString, draft.signatureSlotID?.uuidString,
                draft.styleRegisterID?.uuidString, draft.styleControlSnapshotJSON,
                draft.orderedRevisions.map { $0.id.uuidString }.joined(separator: ","),
                message?.id.uuidString, message?.subject, message?.fromAddress,
                message?.fromName, message?.replyToAddressesJSON,
                message?.bodyTextPath, message?.contentHash, message?.languageDetected,
                message?.accountID?.uuidString, message?.account?.id.uuidString,
            ]
            pendingStyleControls = draft.pendingStyleControlSnapshotJSON
            pendingStyleRegisterID = draft.pendingStyleRegisterID
        }
    }

    private struct QuestionEvaluationInputs {
        let contextPack: ComposerContextPack
        let subject: String
        let accountID: UUID?
        let languageIdentifier: String
        let questionLanguage: SummarizationTargetLanguage
        let userName: String
        let counterpartName: String
        let framing: ComposerInterviewFraming
        let recipients: [String]
        let sendingIdentity: String?
        let draftGuidance: String?
        let inputFingerprint: String
        let associatedMessageID: UUID?
        let recipientState: QuestionRecipientState
        let composeInstruction: String?
        let fromIdentityID: UUID?
    }

    private struct QuestionGroundingAwaitSnapshot {
        let draftID: UUID
        let statusRawValue: String
        let stageRaw: String?
        let interviewStateJSON: String?
        let sourcesJSON: String?
        let languageIdentifier: String
        let framingRawValue: String
        let accountID: UUID?
        let subject: String
        let evidenceFingerprint: String
        let inputFingerprint: String
        let userName: String
        let counterpartName: String
        let associatedMessageID: UUID?
        let recipientState: QuestionRecipientState
        let composeInstruction: String?
        let fromIdentityID: UUID?
    }

    private let draftOrchestrator: any DraftGenerating
    private let interviewPlanner: ComposerInterviewPlanner?
    private let interviewRepairer: ComposerInterviewRepairer?
    private let questionGroundingResolver: QuestionGroundingResolver?
    private let sourceSelector: LLMComposerSourceSelector?
    private let hybridRetriever: HybridRetriever?
    private let contextPacker: ComposerContextPacker
    private let contextPackingFailureHandler:
        (@MainActor @Sendable (ComposerContextPackingError) -> Void)?
    private let replySourceCompiler: any ReplySourceCompiling
    private let automaticTriageQueueingEnabled: Bool
    private let relatedAffinityProvider: (any ComposerRelatedAffinityProviding)?
    private let webResearchPlanner: (any ComposerWebResearchPlanning)?
    private let externalResearchProvider: (any ComposerExternalResearching)?
    private let messagesProvider: any MessagesTranscriptProviding
    private let automaticWebsiteSourceExpander: AutomaticWebsiteSourceExpander
    private let encoder = JSONEncoder()

    @MainActor
    private static var draftsBeingGrounded: Set<UUID> = []

    public init(
        draftOrchestrator: any DraftGenerating,
        interviewPlanner: ComposerInterviewPlanner? = nil,
        interviewRepairer: ComposerInterviewRepairer? = nil,
        questionGroundingResolver: QuestionGroundingResolver? = nil,
        sourceSelector: LLMComposerSourceSelector? = nil,
        hybridRetriever: HybridRetriever? = nil,
        contextPacker: ComposerContextPacker = ComposerContextPacker(tokenCounter: nil),
        contextPackingFailureHandler:
            (@MainActor @Sendable (ComposerContextPackingError) -> Void)? = nil,
        replySourceCompiler: (any ReplySourceCompiling)? = nil,
        automaticTriageQueueingEnabled: Bool = ComposerQueueIntakePreference.automaticTriageQueueingEnabled(),
        relatedAffinityProvider: (any ComposerRelatedAffinityProviding)? = nil,
        webResearchPlanner: (any ComposerWebResearchPlanning)? = nil,
        externalResearchProvider: (any ComposerExternalResearching)? = nil,
        messagesProvider: any MessagesTranscriptProviding = UnavailableMessagesTranscriptProvider(),
        automaticWebsiteSourceExpander: AutomaticWebsiteSourceExpander? = nil
    ) {
        let websiteSourceExpander = automaticWebsiteSourceExpander ?? { sources in
            try await WebRAGComposerSourceExpander.expandAutomaticWebsiteSources(sources)
        }
        self.draftOrchestrator = draftOrchestrator
        self.interviewPlanner = interviewPlanner
        self.interviewRepairer = interviewRepairer
        self.questionGroundingResolver = questionGroundingResolver
        self.sourceSelector = sourceSelector
        self.hybridRetriever = hybridRetriever
        self.contextPacker = contextPacker
        self.contextPackingFailureHandler = contextPackingFailureHandler
        self.replySourceCompiler = replySourceCompiler ?? ReplySourceCompiler(
            sourceSelector: sourceSelector,
            hybridRetriever: hybridRetriever,
            contextPacker: contextPacker,
            relatedAffinityProvider: relatedAffinityProvider,
            webResearchPlanner: webResearchPlanner,
            externalResearchProvider: externalResearchProvider,
            messagesProvider: messagesProvider,
            automaticWebsiteSourceExpander: websiteSourceExpander
        )
        self.automaticTriageQueueingEnabled = automaticTriageQueueingEnabled
        self.relatedAffinityProvider = relatedAffinityProvider
        self.webResearchPlanner = webResearchPlanner
        self.externalResearchProvider = externalResearchProvider
        self.messagesProvider = messagesProvider
        self.automaticWebsiteSourceExpander = websiteSourceExpander
    }

    /// Runs the ordered Composer passes within a shared `batchSize` budget of
    /// LLM-heavy operations. Returns the count processed.
    ///
    /// Draft generation is expensive (agent execution + LLM generation) so
    /// callers should keep batchSize small — 2–3 per pipeline tick is typical.
    ///
    /// `priorityMessageID` is the message the user has open in the Composer
    /// (threaded through the job's `messageId` by the scheduler). Every pass
    /// services that message first, so the front window never waits behind
    /// the rest of the backlog.
    @MainActor
    public func generateDraftsForPendingMessages(
        context: ModelContext,
        batchSize: Int = 3,
        priorityMessageID: UUID? = nil
    ) async throws -> Int {
        var budget = max(0, batchSize)
        var processed = 0

        // Pass 0 — exact source-context measurement after manual curation.
        // This is tokenizer work only: it must not advance the Composer stage,
        // ask questions, or generate/revise body text.
        let measured = processSourceContextMeasurements(
            context: context,
            budget: budget,
            priorityMessageID: priorityMessageID
        )
        processed += measured
        budget -= measured

        guard budget > 0 else {
            try context.save()
            return processed
        }

        // Pass 0.5 — compose-from-scratch. A user composing a new email is
        // actively waiting on the model, so an active compose is never blocked
        // behind the reply backlog. Covers question seeding ("Ask questions
        // first"), first-draft generation, and instruction revisions.
        let composed = try await processComposeDrafts(context: context, budget: budget)
        processed += composed
        budget -= composed

        // Pass 1 — instruction revisions. The user typed an instruction and
        // is looking at the Composer; service these before anything else.
        guard budget > 0 else {
            try context.save()
            return processed
        }
        let revised = try await processInstructionRevisions(
            context: context,
            budget: budget,
            priorityMessageID: priorityMessageID
        )
        processed += revised
        budget -= revised

        // Pass 1.5 — app-seeded reply research. Opening Composer can create
        // the local source row before the worker reaches intake; the explicit
        // pending research state lets the worker enrich that same row instead
        // of rejecting it as an existing draft.
        if budget > 0 {
            let researched = try await processPendingReplySourceResearch(
                context: context,
                budget: budget,
                priorityMessageID: priorityMessageID
            )
            processed += researched
            budget -= researched
        }

        // Pass 2 — owed generations (answers submitted, regenerations).
        if budget > 0 {
            let generated = try await processGenerationOwedDrafts(
                context: context,
                budget: budget,
                priorityMessageID: priorityMessageID
            )
            processed += generated
            budget -= generated
        }

        // Pass 2.5 — source evaluations. Sources arrive here automatically
        // after compilation or preparation adoption, and after an explicit
        // Re-check. Run the question generator to decide whether the reply can
        // be drafted as-is or still needs clarifying decisions. This runs ahead
        // of fresh intake.
        if budget > 0 {
            let evaluated = try await processSourceEvaluations(
                context: context,
                budget: budget,
                priorityMessageID: priorityMessageID
            )
            processed += evaluated
            budget -= evaluated
        }

        // Pass 3 — queue intake for newly-queued messages.
        if budget > 0 {
            let seeded = try await seedDraftsForNewMessages(
                context: context,
                budget: budget,
                priorityMessageID: priorityMessageID
            )
            processed += seeded
        }

        try context.save()
        return processed
    }

    /// Orders the targeted message's work first, preserving the existing
    /// ordering for everything else.
    private static func priorityFirst<T>(
        _ items: [T],
        priorityMessageID: UUID?,
        messageID: (T) -> UUID?
    ) -> [T] {
        guard let priorityMessageID else { return items }
        var targeted: [T] = []
        var rest: [T] = []
        for item in items {
            if messageID(item) == priorityMessageID {
                targeted.append(item)
            } else {
                rest.append(item)
            }
        }
        return targeted + rest
    }

    /// True when Composer work is owed beyond fresh intake: drafts the user
    /// flipped to `.generating`, drafts owing a source-evaluation pass, or
    /// drafts left with a pending instruction. The scheduler's reseed uses
    /// this so a transient engine failure can never strand a draft mid-flow
    /// with no queued job. Drafts inside failure backoff or waiting on a
    /// context-pack wake don't count; failure backoff is rediscovered when the
    /// window expires, while context waits are woken by the retrieval worker or
    /// surfaced to the user after the wait timeout.
    @MainActor
    public static func hasPendingComposerWork(context: ModelContext, now: Date = Date()) -> Bool {
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        return drafts.contains { draft in
            draft.kind != .userCompose
                && draft.status == .pending
                && draft.message != nil
                && (draft.nextGenerationAttemptAt ?? .distantPast) <= now
                && !Self.isWaitingForContextPack(draft, now: now)
                && !Self.hasContextPackWaitTimedOut(draft, now: now)
                && (Self.sourceContextMeasurementPending(draft)
                    || draft.resolvedStage == DraftStage.generating
                    || draft.resolvedStage == DraftStage.evaluatingSources
                    || draft.isAutomaticSourceResearchPending
                    || revisionWorkPending(draft))
        }
    }

    // MARK: - Failure backoff

    /// Transport failures receive at most three attempts. Completed invalid
    /// output and oversized input require a changed request or explicit retry.
    /// Context-pack waits are tracked separately because BGE owns the wakeup.
    static let contextPackWaitTimeout: TimeInterval = 180
    public static let maximumAutomaticAttempts = 3

    static func backoffInterval(forFailureCount count: Int) -> TimeInterval {
        let exponent = min(max(0, count - 1), 7)
        return min(30 * pow(2, Double(exponent)), 3600)
    }

    @MainActor
    private func recordGenerationFailure(on draft: Draft, error: Error, now: Date = Date()) {
        let count = (draft.generationFailureCount ?? 0) + 1
        draft.generationFailureCount = count
        draft.generationFailureDescription = error.localizedDescription
        draft.generationFailureStage = draft.resolvedStage
        draft.contextPackWaitStartedAt = nil
        // Keep rejected content intact for an explicit retry. A deadline is
        // transient and shares the same bounded retries as model transport.
        let terminalContentFailure = (error as? ComposerContentError).map {
            $0 != .deadlineExceeded
        } ?? false
        draft.nextGenerationAttemptAt = error is DraftContentValidationError
            || terminalContentFailure
            || error is ComposerContextPackingError
            || count >= Self.maximumAutomaticAttempts
            ? .distantFuture
            : now.addingTimeInterval(Self.backoffInterval(forFailureCount: count))
    }

    @MainActor
    private func recordContextPackWait(on draft: Draft, now: Date = Date()) {
        if draft.contextPackWaitStartedAt == nil {
            draft.contextPackWaitStartedAt = now
        }
        draft.nextGenerationAttemptAt = nil
    }

    public static func isWaitingForContextPack(_ draft: Draft, now: Date = Date()) -> Bool {
        guard draft.kind != .userCompose,
              draft.status == .pending,
              draft.resolvedStage == DraftStage.generating,
              draft.generationFailureCount == nil,
              let startedAt = draft.contextPackWaitStartedAt else {
            return false
        }
        return now.timeIntervalSince(startedAt) < Self.contextPackWaitTimeout
    }

    public static func hasContextPackWaitTimedOut(_ draft: Draft, now: Date = Date()) -> Bool {
        guard draft.kind != .userCompose,
              draft.status == .pending,
              draft.resolvedStage == DraftStage.generating,
              draft.generationFailureCount == nil,
              let startedAt = draft.contextPackWaitStartedAt else {
            return false
        }
        return now.timeIntervalSince(startedAt) >= Self.contextPackWaitTimeout
    }

    @MainActor
    private func clearGenerationFailure(on draft: Draft) {
        draft.clearGenerationBackoff()
    }

    @MainActor
    private static func isEligibleForAttempt(_ draft: Draft, now: Date) -> Bool {
        (draft.nextGenerationAttemptAt ?? .distantPast) <= now
    }

    /// Store-keyed Message lookup used after suspension points. MainActor
    /// reentrancy means the registered instance captured before an `await`
    /// may no longer represent the row that is eligible for intake.
    @MainActor
    private static func storedMessage(id: UUID, context: ModelContext) throws -> Message? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { message in
            message.id == id
        })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Store-keyed Draft lookup. The Composer (app process) and this worker
    /// can both create the Draft row for a message; a registered `Message`
    /// object's `draft` relationship may still be a stale nil while the
    /// other process's row already exists in the store. Every creation site
    /// re-checks through a real fetch before inserting so the one-to-one
    /// relationship can't fork into an orphaned duplicate.
    @MainActor
    private static func storedDraft(for messageID: UUID, context: ModelContext) -> Draft? {
        var descriptor = FetchDescriptor<Draft>(predicate: #Predicate<Draft> { draft in
            draft.message?.id == messageID
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Throwing variant for the post-compilation intake boundary. A failed
    /// fetch cannot be treated as authoritative proof that no Draft exists.
    @MainActor
    private static func storedIntakeDraft(
        for messageID: UUID,
        context: ModelContext
    ) throws -> Draft? {
        var descriptor = FetchDescriptor<Draft>(predicate: #Predicate<Draft> { draft in
            draft.message?.id == messageID
        })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    private static func storedDraft(id: UUID, context: ModelContext) -> Draft? {
        var descriptor = FetchDescriptor<Draft>(predicate: #Predicate<Draft> { draft in
            draft.id == id
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Revalidates the durable Composer owner after model or research work
    /// suspends. Publication must never rely on the worker's registered model,
    /// because the app process can discard or delete that row meanwhile.
    @MainActor
    private static func requireActiveComposerTarget(
        draftID: UUID? = nil,
        messageID: UUID? = nil,
        context: ModelContext
    ) throws {
        try Task.checkCancellation()
        let authoritativeContext = ModelContext(context.container)
        if let draftID {
            var descriptor = FetchDescriptor<Draft>(
                predicate: #Predicate<Draft> { $0.id == draftID }
            )
            descriptor.fetchLimit = 1
            guard let draft = try authoritativeContext.fetch(descriptor).first,
                  draft.status == .pending else {
                throw CancellationError()
            }
        }
        if let messageID {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            descriptor.fetchLimit = 1
            guard let message = try authoritativeContext.fetch(descriptor).first,
                  message.composerQueueOverride != .exclude else {
                throw CancellationError()
            }
        }
        ComposerPublicationTesting.beforePublication?()
        try Task.checkCancellation()
    }

    @MainActor
    private static func requireCurrentDraftInputs(
        _ snapshot: DraftInputSnapshot,
        draft: Draft,
        context: ModelContext,
        acceptingNewerStyleDecision: Bool = false
    ) throws {
        try requireActiveComposerTarget(
            draftID: draft.id,
            messageID: draft.message?.id,
            context: context
        )
        let authoritativeContext = ModelContext(context.container)
        let draftID = draft.id
        var descriptor = FetchDescriptor<Draft>(predicate: #Predicate { $0.id == draftID })
        descriptor.fetchLimit = 1
        guard let fresh = try authoritativeContext.fetch(descriptor).first else {
            throw CancellationError()
        }
        let local = DraftInputSnapshot(draft: draft)
        let stored = DraftInputSnapshot(draft: fresh)
        guard snapshot.values == local.values,
              snapshot.values == stored.values,
              acceptingNewerStyleDecision || (snapshot == local && snapshot == stored) else {
            throw CancellationError()
        }
    }

    // MARK: - Pass 1: instruction revisions

    @MainActor
    private func processInstructionRevisions(
        context: ModelContext,
        budget: Int,
        priorityMessageID: UUID? = nil
    ) async throws -> Int {
        guard budget > 0,
              let revising = draftOrchestrator as? any DraftRevising else { return 0 }
        let now = Date()
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        // A draft that owes a full generation (new answers, sources or
        // language) is written afresh first; that pass takes the pending style
        // and controls, and a typed instruction then revises the new body. A
        // draft whose sources and questions are being evaluated (Re-check, a
        // typed answer's repair) finishes that first.
        let waitingByAge = drafts.filter { draft in
            draft.kind != .userCompose
                && draft.status == .pending
                && draft.message != nil
                && draft.resolvedStage != DraftStage.generating
                && draft.resolvedStage != DraftStage.evaluatingSources
                && Self.isEligibleForAttempt(draft, now: now)
                && Self.revisionWorkPending(draft)
        }
        .sorted { $0.generatedAt < $1.generatedAt }
        let waiting = Self.priorityFirst(
            waitingByAge,
            priorityMessageID: priorityMessageID,
            messageID: { $0.message?.id }
        )

        var processed = 0
        for draft in waiting.prefix(budget) {
            guard let message = draft.message else { continue }
            var revisionInputs: DraftInputSnapshot?

            // Validate a pending register switch before burning a
            // generation: a retired or deleted register can't restyle
            // anything, so a dead pointer is dropped instead of retried.
            let restyleRegisterID = validatedPendingRegisterID(on: draft, context: context)

            let typed = draft.pendingInstruction?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isRegeneration = typed == Self.regenerationInstruction
            guard typed?.isEmpty == false || restyleRegisterID != nil else { continue }

            do {
                try await ensureAutomaticSources(on: draft, message: message, context: context)
                guard draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) == typed else {
                    throw CancellationError()
                }
                try repairPendingTypedAnswer(on: draft, framing: .reply, context: context)
                Self.refreshPendingStyleControlDecision(on: draft, context: context)
                let instruction: String
                if let typed, !typed.isEmpty {
                    instruction = typed
                } else {
                    instruction = Self.restyleInstruction
                }
                let registerID = restyleRegisterID ?? draft.styleRegisterID
                let registerNote = styleRegisterNote(
                    registerID: registerID,
                    languageID: DraftLanguage.resolvedID(for: message),
                    context: context
                )
                if let typed,
                   typed.isEmpty == false,
                   isRegeneration == false,
                   typed != Self.restyleInstruction,
                   draft.stageRevisionStyleControlDecision(
                       instruction: typed,
                       registerID: registerID,
                       registerRevision: registerNote?.revision,
                       defaults: registerNote?.axes
                   ) != nil {
                    // Make the reconciled pending controls visible to the
                    // Style pane before the model begins its revision.
                    try context.save()
                }
                // Capture after the potentially-suspending source check and
                // immediately before prompt construction, so a slider move
                // made during that wait cannot mislabel the resulting body.
                let styleControlSnapshot = DraftOrchestrator.styleControlSnapshot(
                    for: draft,
                    register: registerNote,
                    includingPending: true
                )
                let consumedStyleDecisionID = draft.pendingStyleControlSnapshot.flatMap {
                    $0.decisionID == styleControlSnapshot?.decisionID ? $0.decisionID : nil
                }
                let inputs = DraftInputSnapshot(draft: draft)
                try context.save()
                try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                revisionInputs = inputs
                let revisionOutput = try await revising.generateRevision(
                    for: message,
                    currentDraft: draft.replyText,
                    instruction: instruction,
                    context: context
                )
                try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                Self.refreshPendingStyleControlDecision(on: draft, context: context, includingRegister: true)
                let withSignature = applyingSignature(
                    to: revisionOutput.replyText,
                    draft: draft,
                    message: message
                )
                appendRevision(
                    to: draft,
                    bodyText: withSignature,
                    trigger: isRegeneration
                        ? DraftRevisionTrigger.regenerate
                        : (restyleRegisterID != nil
                            ? DraftRevisionTrigger.restyle
                            : DraftRevisionTrigger.instruction),
                    instruction: isRegeneration
                        ? nil
                        : ((typed?.isEmpty == false) ? typed : nil),
                    styleRegisterID: restyleRegisterID ?? draft.styleRegisterID,
                    styleControlSnapshot: styleControlSnapshot,
                    reasoningContent: revisionOutput.reasoningContent,
                    reasoningContinuationFingerprint: revisionOutput.reasoningContinuationFingerprint,
                    reasoningPrompt: revisionOutput.reasoningPrompt,
                    generationBasisJSON: revisionOutput.generationBasisJSON,
                    context: context
                )
                draft.replyText = withSignature
                draft.bodyHTML = nil
                publishRevisionPersonalization(revisionOutput, on: draft, context: context)
                draft.pendingInstruction = nil
                draft.applyGeneratedStyleControlSnapshot(
                    styleControlSnapshot,
                    consumedDecisionID: consumedStyleDecisionID
                )
                if let restyleRegisterID {
                    draft.styleRegisterID = restyleRegisterID
                    // Drain only the pick this pass honored; a newer pick
                    // made mid-generation stays pending for the next pass.
                    if draft.pendingStyleRegisterID == restyleRegisterID {
                        draft.pendingStyleRegisterID = nil
                    }
                }
                // The strict snapshot check above rejects a language, stage,
                // or control change made while this request was running.
                draft.stageRaw = DraftStage.drafted
                Self.applyWriterWindowUsage(revisionOutput.writerWindowUsage, to: draft)
                clearGenerationFailure(on: draft)
                processed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let revisionInputs {
                    try Self.requireCurrentDraftInputs(
                        revisionInputs, draft: draft, context: context,
                        acceptingNewerStyleDecision: false
                    )
                }
                recordGenerationFailure(on: draft, error: error)
                print("[Ohia] ⚠ Draft revision failed for \(draft.id): \(String(reflecting: type(of: error)))")
            }
            // Publish before another draft can suspend the worker. Save
            // failures propagate as persistence errors, not model failures.
            try context.save()
        }
        return processed
    }

    /// Completes automatic research on a reply row the app created first.
    /// The pending flag is a cross-process ownership token: Composer locks
    /// source curation until this pass merges the full automatic evidence set
    /// and marks the row complete.
    @MainActor
    private func processPendingReplySourceResearch(
        context: ModelContext,
        budget: Int,
        priorityMessageID: UUID? = nil
    ) async throws -> Int {
        guard budget > 0 else { return 0 }
        let now = Date()
        let drafts = ((try? context.fetch(FetchDescriptor<Draft>())) ?? [])
            .filter { draft in
                draft.kind != .userCompose
                    && draft.status == .pending
                    && draft.message != nil
                    && draft.isAutomaticSourceResearchPending
                    && Self.isEligibleForAttempt(draft, now: now)
            }
            .sorted { $0.generatedAt < $1.generatedAt }
        let ordered = Self.priorityFirst(
            drafts,
            priorityMessageID: priorityMessageID,
            messageID: { $0.message?.id }
        )

        var processed = 0
        for draft in ordered.prefix(budget) {
            guard let message = draft.message else { continue }
            let userAdded = ComposerSourceCoding.decode(draft.sourcesJSON).filter(\.isUserAdded)
            try context.save()
            let inputs = DraftInputSnapshot(draft: draft)
            do {
                let snapshot = try await replySourceCompiler.compile(
                    for: message,
                    context: context,
                    preservingUserAddedSources: userAdded
                )
                try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                draft.sourcesJSON = snapshot.sourcesJSON
                draft.sourceThreadCoverageJSON = snapshot.threadCoverageJSON
                draft.sourceThreadCount = snapshot.sourceThreadCount
                refreshWriterWindowUsage(on: draft)
                draft.sourceContextMeasurementRequestedAt = nil
                draft.completeAutomaticSourceResearch()
                draft.stageRaw = DraftStage.evaluatingSources
                clearGenerationFailure(on: draft)
                processed += 1
            } catch let error as ComposerContextPackingError {
                try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                recordGenerationFailure(on: draft, error: error)
                contextPackingFailureHandler?(error)
                print("[Ohia] ⚠ Reply context packing failed for \(draft.id): \(String(reflecting: type(of: error)))")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                recordGenerationFailure(on: draft, error: error)
            }
        }
        return processed
    }

    /// Lifecycle marker for Regenerate. The canonical request compiler omits
    /// this from author instructions and reads the selected controls directly.
    public static let regenerationInstruction = """
    Revise the current draft in place only as needed to reflect the current \
    sources and settings. Preserve its facts, decisions, commitments, \
    recipients, language, organization, and wording unless a changed input \
    requires an adjustment. Do not create a fresh alternative or restart from \
    the original sources.
    """

    /// Style-only work uses the current body and the same canonical controls
    /// as every other generation path; no alternate style prompt is created.
    @MainActor
    private static func hasPendingStyleOnlyRegeneration(_ draft: Draft) -> Bool {
        guard draft.pendingStyleRegisterID == nil,
              hasPendingGenerationSourceChanges(draft) == false,
              let pendingSnapshot = draft.pendingStyleControlSnapshot,
              let requested = pendingSnapshot.effectiveAxes,
              let applied = draft.styleControlSnapshot?.effectiveAxes
                ?? pendingSnapshot.baseAxes else {
            return false
        }
        return requested != applied
    }

    @MainActor
    private static func hasPendingGenerationSourceChanges(_ draft: Draft) -> Bool {
        guard let generatedSourcesJSON = draft.generatedSourcesJSON else { return true }
        let generated = ComposerSourceCoding.decode(generatedSourcesJSON)
        let selected = DraftOrchestrator.generationSources(
            for: draft,
            selected: ComposerSourceCoding.decode(draft.sourcesJSON)
        )
        return generated != selected
    }

    /// Synthesized revision instruction for a pure register switch — the
    /// user picked a different style but typed nothing. Rewrite the voice,
    /// keep the substance.
    static let restyleInstruction = """
    Rewrite the current draft in the voice described in [STYLE REGISTER]. \
    Keep every fact, decision, commitment, and the language exactly as they \
    are; change only the tone, phrasing, and style.
    """

    /// True when the draft owes an instruction revision or a restyle. A
    /// pending register switch only counts once a *model-generated* body
    /// exists to rewrite (at least one revision) — before first generation
    /// the switch is honored by the initial pass instead. Gating on
    /// `replyText` alone would be wrong for composes: a blank compose
    /// carries the materialized signature (and possibly hand-typed text the
    /// model never wrote) in `replyText`, and a restyle pass would overwrite
    /// it unasked.
    @MainActor
    private static func revisionWorkPending(_ draft: Draft) -> Bool {
        if draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return draft.pendingStyleRegisterID != nil
            && (draft.revisions ?? []).isEmpty == false
    }

    /// The draft's pending register switch when the register still exists
    /// and is active; a dead pointer is cleared so it can't retry forever.
    @MainActor
    private func validatedPendingRegisterID(on draft: Draft, context: ModelContext) -> UUID? {
        guard let pendingID = draft.pendingStyleRegisterID else { return nil }
        let languageID = draft.kind == .userCompose
            ? DraftLanguage.familyID(for: draft.languageID)
            : draft.message.flatMap { DraftLanguage.resolvedID(for: $0) }
        if StyleRegisterResolver.register(
            withID: pendingID,
            language: languageID,
            context: context
        ) != nil {
            return pendingID
        }
        draft.pendingStyleRegisterID = nil
        return nil
    }

    // MARK: - Pass 2: owed generations

    @MainActor
    private func processGenerationOwedDrafts(
        context: ModelContext,
        budget: Int,
        priorityMessageID: UUID? = nil
    ) async throws -> Int {
        guard budget > 0 else { return 0 }
        let now = Date()
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        let owedByAge = drafts.filter { draft in
            draft.kind != .userCompose
                && draft.status == .pending
                && draft.message != nil
                && Self.isEligibleForAttempt(draft, now: now)
                && !Self.isWaitingForContextPack(draft, now: now)
                && !Self.hasContextPackWaitTimedOut(draft, now: now)
                && draft.resolvedStage == DraftStage.generating
        }
        .sorted { $0.generatedAt < $1.generatedAt }
        let owed = Self.priorityFirst(
            owedByAge,
            priorityMessageID: priorityMessageID,
            messageID: { $0.message?.id }
        )

        var processed = 0
        for draft in owed.prefix(budget) {
            guard let message = draft.message else { continue }
            do {
                try await ensureAutomaticSources(on: draft, message: message, context: context)
                try await generateAndPersist(for: message, context: context)
                clearGenerationFailure(on: draft)
                processed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch GenerationContextPackError.missing(let messageID) {
                recordContextPackWait(on: draft)
                print("[Ohia] Draft generation waiting for context pack for \(messageID)")
            } catch {
                recordGenerationFailure(on: draft, error: error)
                print("[Ohia] ⚠ Draft generation failed for \(message.id): \(String(reflecting: type(of: error)))")
            }
            try context.save()
        }
        return processed
    }

    /// Guarantees a legacy draft entering generation carries the automatic
    /// evidence set. Once `sourcesJSON` exists, the Composer treats it as the
    /// user's curated source list — including intentionally user-only or empty
    /// lists — so regeneration never restores sources the user removed.
    @MainActor
    private func ensureAutomaticSources(
        on draft: Draft,
        message: Message,
        context: ModelContext
    ) async throws {
        guard draft.sourcesJSON == nil else { return }
        let snapshot = try await replySourceCompiler.compile(
            for: message,
            context: context,
            preservingUserAddedSources: []
        )
        try Self.requireActiveComposerTarget(
            draftID: draft.id,
            messageID: message.id,
            context: context
        )
        draft.sourcesJSON = snapshot.sourcesJSON
        draft.sourceThreadCoverageJSON = snapshot.threadCoverageJSON
        draft.sourceThreadCount = snapshot.sourceThreadCount
        refreshWriterWindowUsage(on: draft)
        draft.sourceContextMeasurementRequestedAt = nil
    }

    // MARK: - Pass 0: compose-from-scratch

    /// True when any `.userCompose` draft owes work: question seeding (an
    /// "Ask questions first" draft with a brief but no questions yet), an owed
    /// first-draft generation, or a pending revision instruction. The
    /// scheduler's reseed uses this so a compose can never strand with no
    /// queued `.generateDraft` job after a transient failure.
    @MainActor
    public static func hasPendingComposeWork(context: ModelContext, now: Date = Date()) -> Bool {
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        return drafts.contains { draft in
            draft.kind == .userCompose
                && draft.status == .pending
                && (draft.nextGenerationAttemptAt ?? .distantPast) <= now
                && (sourceContextMeasurementPending(draft)
                    || composeWorkPending(draft))
        }
    }

    @MainActor
    private static func sourceContextMeasurementPending(_ draft: Draft) -> Bool {
        draft.sourceContextMeasurementRequestedAt != nil
    }

    /// Re-runs only the authoritative packer and the writer fit for drafts
    /// whose source list was edited in Composer. The stage and all
    /// interview/body fields remain untouched; successful packing may still
    /// clip or displace lower-priority automatic sources under the same rules
    /// used during compilation. A failed measurement still records the writer
    /// budget, so the app does not request it again until sources change.
    @MainActor
    private func processSourceContextMeasurements(
        context: ModelContext,
        budget: Int,
        priorityMessageID: UUID?
    ) -> Int {
        guard budget > 0 else { return 0 }
        let drafts = ((try? context.fetch(FetchDescriptor<Draft>())) ?? [])
            .filter { $0.status == .pending && Self.sourceContextMeasurementPending($0) }
            .sorted {
                ($0.sourceContextMeasurementRequestedAt ?? .distantPast)
                    < ($1.sourceContextMeasurementRequestedAt ?? .distantPast)
            }
        let ordered = Self.priorityFirst(
            drafts,
            priorityMessageID: priorityMessageID,
            messageID: { $0.message?.id }
        )

        var processed = 0
        for draft in ordered.prefix(budget) {
            do {
                if draft.kind == .userCompose {
                    try persistPackedComposeSources(
                        ComposerSourceCoding.decode(draft.sourcesJSON),
                        on: draft
                    )
                } else if let message = draft.message {
                    try persistPackedReplySources(
                        ComposerSourceCoding.decode(draft.sourcesJSON),
                        on: draft,
                        message: message
                    )
                } else {
                    Self.recordUnavailableSourceContextMeasurement(on: draft)
                }
            } catch let error as ComposerContextPackingError {
                // The manual-add preflight normally prevents this. Clear the
                // request so an exact tokenizer disagreement cannot spin the
                // worker; the existing source-capacity warning remains the
                // user-facing recovery path.
                Self.recordUnavailableSourceContextMeasurement(on: draft)
                contextPackingFailureHandler?(error)
            } catch {
                Self.recordUnavailableSourceContextMeasurement(on: draft)
                print("[Ohia] Composer source-context measurement failed: \(String(reflecting: type(of: error)))")
            }
            processed += 1
        }
        return processed
    }

    /// Classifies the compose work a draft owes (nil = none / waiting on the
    /// user). Drives both the pass router and `hasPendingComposeWork`.
    private enum ComposeWork { case researchSources, evaluateSources, firstDraft, revision }

    /// A full pass writes from the current sources and settings, which is
    /// all a regeneration queued before it asks for; a typed instruction
    /// still waits to revise the new body.
    @MainActor
    private static func clearRegenerationCoveredByFullPass(on draft: Draft) {
        if draft.pendingInstruction == regenerationInstruction {
            draft.pendingInstruction = nil
        }
    }

    /// A compose draft at `.generating` owes a full pass, not a revision of
    /// its body, when it has no generated body yet, or its decisions, sources
    /// or language changed since its latest full generation. A restyle or
    /// instruction queued meanwhile waits for the new body. A full pass that
    /// cannot run (no brief or recipient yet) leaves the queued revision to
    /// run as before.
    @MainActor
    private static func owesFullComposeGeneration(_ draft: Draft) -> Bool {
        guard draft.resolvedStage == DraftStage.generating,
              (draft.composeInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              (ComposeAddressEncoding.decode(draft.composeToJSON).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return (draft.revisions ?? []).isEmpty
            || hasPendingGenerationSourceChanges(draft)
            || ComposerDecisionHistoryPersistence.hasPendingDecisionChanges(on: draft)
            || ComposerDecisionHistoryPersistence.hasPendingLanguageChange(on: draft)
    }

    @MainActor
    private static func composeWork(for draft: Draft) -> ComposeWork? {
        // Sources and questions under evaluation finish before any revision.
        if revisionWorkPending(draft),
           draft.resolvedStage != DraftStage.evaluatingSources,
           !owesFullComposeGeneration(draft) {
            return .revision
        }

        let hasBrief = (draft.composeInstruction ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasRecipient = (ComposeAddressEncoding.decode(draft.composeToJSON).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasSubject = (draft.composeSubject ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if draft.isAutomaticSourceResearchPending,
           draft.resolvedStage == DraftStage.collectingSources {
            // New-message source determination is the step before Draft
            // Guidance. Recipient + subject are therefore the complete frame
            // for this pass; the later guidance drives question evaluation.
            return (hasRecipient && hasSubject) ? .researchSources : nil
        }
        switch draft.resolvedStage {
        case DraftStage.evaluatingSources:
            // The user curated the sources and pressed Continue; the worker
            // owes the deferred question-evaluation pass against the brief +
            // curated sources. Without a brief there is nothing to evaluate.
            return hasBrief ? .evaluateSources : nil
        case DraftStage.generating:
            if !owesFullComposeGeneration(draft),
               hasPendingStyleOnlyRegeneration(draft) {
                return .revision
            }
            // A first draft needs a brief and a recipient; without them the
            // generation would only throw and spin the failure backoff. A
            // blank compose at the reply-default `.generating` stage owes
            // nothing until the user supplies a brief via "Draft now".
            return (hasBrief && hasRecipient) ? .firstDraft : nil
        default:
            // `collectingSources` (curating) and `collectingAnswers` (answering
            // post-evaluation) both wait on the user.
            return nil
        }
    }

    @MainActor
    private static func composeWorkPending(_ draft: Draft) -> Bool {
        composeWork(for: draft) != nil
    }

    @MainActor
    private func processComposeDrafts(context: ModelContext, budget: Int) async throws -> Int {
        guard budget > 0,
              let composing = draftOrchestrator as? any DraftComposing else { return 0 }
        let now = Date()
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        let eligible = drafts.filter { draft in
            draft.kind == .userCompose
                && draft.status == .pending
                && Self.isEligibleForAttempt(draft, now: now)
                && Self.composeWorkPending(draft)
        }
        .sorted { $0.generatedAt < $1.generatedAt }

        var processed = 0
        for draft in eligible.prefix(budget) {
            guard let work = Self.composeWork(for: draft) else {
                continue
            }
            var generationInputs: DraftInputSnapshot?
            do {
                let initialResearchOwnsCompilation: Bool
                switch work {
                case .researchSources, .firstDraft:
                    initialResearchOwnsCompilation = draft.isAutomaticSourceResearchPending
                case .evaluateSources, .revision:
                    initialResearchOwnsCompilation = false
                }
                if !initialResearchOwnsCompilation {
                    try await ensureComposeAutomaticSources(on: draft, context: context)
                }
                switch work {
                case .researchSources:
                    let researchIsCurrent = try await performInitialComposeResearch(
                        on: draft,
                        context: context
                    )
                    guard researchIsCurrent else {
                        processed += 1
                        continue
                    }
                case .evaluateSources:
                    let outcome = try await evaluateComposeSources(for: draft, context: context)
                    switch outcome {
                    case .completed(let currentDraft):
                        clearGenerationFailure(on: currentDraft)
                        processed += 1
                    case .stale:
                        processed += 1
                    case .alreadyInFlight:
                        break
                    }
                    continue
                case .firstDraft:
                    guard try await performInitialComposeResearch(
                        on: draft,
                        context: context
                    ) else {
                        processed += 1
                        continue
                    }
                    try repairPendingTypedAnswer(on: draft, framing: .compose, context: context)
                    guard try await prepareDecisionResearchOverlay(
                        on: draft,
                        message: nil,
                        context: context
                    ) else {
                        processed += 1
                        continue
                    }
                    let inputs = DraftInputSnapshot(draft: draft)
                    try context.save()
                    try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                    generationInputs = inputs
                    let output = try await composing.generateCompose(for: draft, context: context)
                    try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                    persistComposeGeneration(output: output, draft: draft, context: context)
                case .revision:
                    let restyleRegisterID = validatedPendingRegisterID(on: draft, context: context)
                    let typed = draft.pendingInstruction?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    Self.refreshPendingStyleControlDecision(on: draft, context: context)
                    let isStyleRegeneration = typed?.isEmpty != false
                        && Self.hasPendingStyleOnlyRegeneration(draft)
                    let isRegeneration = typed == Self.regenerationInstruction
                        || isStyleRegeneration
                    let registerID = restyleRegisterID ?? draft.styleRegisterID
                    let registerNote = styleRegisterNote(
                        registerID: registerID,
                        languageID: DraftLanguage.familyID(for: draft.languageID),
                        context: context
                    )
                    let instruction: String
                    if let typed, !typed.isEmpty {
                        instruction = typed
                    } else if restyleRegisterID != nil {
                        instruction = Self.restyleInstruction
                    } else if isStyleRegeneration {
                        instruction = Self.regenerationInstruction
                    } else {
                        continue
                    }
                    try repairPendingTypedAnswer(on: draft, framing: .compose, context: context)
                    if let typed,
                       typed.isEmpty == false,
                       isRegeneration == false,
                       typed != Self.restyleInstruction,
                       draft.stageRevisionStyleControlDecision(
                           instruction: typed,
                           registerID: registerID,
                           registerRevision: registerNote?.revision,
                           defaults: registerNote?.axes
                       ) != nil {
                        try context.save()
                    }
                    let styleControlSnapshot = DraftOrchestrator.styleControlSnapshot(
                        for: draft,
                        register: registerNote,
                        includingPending: true
                    )
                    let consumedStyleDecisionID = draft.pendingStyleControlSnapshot.flatMap {
                        $0.decisionID == styleControlSnapshot?.decisionID ? $0.decisionID : nil
                    }
                    let inputs = DraftInputSnapshot(draft: draft)
                    try context.save()
                    try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                    generationInputs = inputs
                    let revisionOutput = try await composing.generateComposeRevision(
                        for: draft,
                        currentDraft: draft.replyText,
                        instruction: instruction,
                        context: context
                    )
                    try Self.requireCurrentDraftInputs(inputs, draft: draft, context: context)
                    Self.refreshPendingStyleControlDecision(on: draft, context: context, includingRegister: true)
                    appendRevision(
                        to: draft,
                        bodyText: revisionOutput.replyText,
                        trigger: restyleRegisterID != nil
                            ? DraftRevisionTrigger.restyle
                            : (isRegeneration
                                ? DraftRevisionTrigger.regenerate
                                : DraftRevisionTrigger.instruction),
                        instruction: isRegeneration
                            ? nil
                            : ((typed?.isEmpty == false) ? typed : nil),
                        styleRegisterID: restyleRegisterID ?? draft.styleRegisterID,
                        styleControlSnapshot: styleControlSnapshot,
                        reasoningContent: revisionOutput.reasoningContent,
                        reasoningContinuationFingerprint: revisionOutput.reasoningContinuationFingerprint,
                        reasoningPrompt: revisionOutput.reasoningPrompt,
                        generationBasisJSON: revisionOutput.generationBasisJSON,
                        context: context
                    )
                    draft.replyText = revisionOutput.replyText
                    draft.bodyHTML = nil
                    Self.applyWriterWindowUsage(revisionOutput.writerWindowUsage, to: draft)
                    publishRevisionPersonalization(revisionOutput, on: draft, context: context)
                    draft.pendingInstruction = nil
                    draft.applyGeneratedStyleControlSnapshot(
                        styleControlSnapshot,
                        consumedDecisionID: consumedStyleDecisionID
                    )
                    if let restyleRegisterID {
                        draft.styleRegisterID = restyleRegisterID
                        // Drain only the pick this pass honored; a newer
                        // pick made mid-generation stays pending.
                        if draft.pendingStyleRegisterID == restyleRegisterID {
                            draft.pendingStyleRegisterID = nil
                        }
                    }
                    draft.stageRaw = DraftStage.drafted
                }
                clearGenerationFailure(on: draft)
                processed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ComposerContextPackingError {
                if let generationInputs {
                    try Self.requireCurrentDraftInputs(
                        generationInputs, draft: draft, context: context,
                        acceptingNewerStyleDecision: false
                    )
                }
                switch work {
                case .evaluateSources:
                    if let currentDraft = currentEvaluationDraft(
                        id: draft.id,
                        context: context
                    ) {
                        holdOversizedContext(
                            on: currentDraft,
                            framing: "Compose",
                            error: error
                        )
                    }
                case .researchSources:
                    // Packing can fail on a mandatory user-added source.
                    // End worker ownership while preserving the broad source
                    // set so the Composer returns to editable curation instead
                    // of trapping the draft behind a permanent progress row.
                    draft.completeAutomaticSourceResearch()
                    draft.stageRaw = DraftStage.collectingSources
                    recordGenerationFailure(on: draft, error: error)
                    contextPackingFailureHandler?(error)
                    print(
                        "[Ohia] ⚠ Initial compose source packing failed for "
                            + "\(draft.id); returning to curation errorKind="
                            + String(reflecting: type(of: error))
                    )
                case .firstDraft:
                    if draft.isAutomaticSourceResearchPending {
                        draft.completeAutomaticSourceResearch()
                        draft.stageRaw = DraftStage.collectingSources
                        recordGenerationFailure(on: draft, error: error)
                        contextPackingFailureHandler?(error)
                        print(
                            "[Ohia] ⚠ Initial compose source packing failed for "
                                + "\(draft.id); returning to curation errorKind="
                                + String(reflecting: type(of: error))
                        )
                    } else {
                        recordGenerationFailure(on: draft, error: error)
                        contextPackingFailureHandler?(error)
                        print("[Ohia] ⚠ Compose context packing failed for \(draft.id): \(String(reflecting: type(of: error)))")
                    }
                case .revision:
                    recordGenerationFailure(on: draft, error: error)
                    contextPackingFailureHandler?(error)
                    print("[Ohia] ⚠ Compose context packing failed for \(draft.id): \(String(reflecting: type(of: error)))")
                }
            } catch {
                if let generationInputs {
                    try Self.requireCurrentDraftInputs(
                        generationInputs, draft: draft, context: context,
                        acceptingNewerStyleDecision: false
                    )
                }
                let failedDuringInitialResearch: Bool
                switch work {
                case .researchSources, .firstDraft:
                    failedDuringInitialResearch = draft.isAutomaticSourceResearchPending
                case .evaluateSources, .revision:
                    failedDuringInitialResearch = false
                }
                if failedDuringInitialResearch {
                    // Automatic source research is advisory. A selector/model
                    // failure must not leave Composer locked behind a pending
                    // ownership token and an exponential retry. Selection
                    // failures preserve the broad deterministic candidates,
                    // so return them to editable curation.
                    draft.completeAutomaticSourceResearch()
                    draft.stageRaw = DraftStage.collectingSources
                    recordGenerationFailure(on: draft, error: error)
                    print(
                        "[Ohia] ⚠ Initial compose source research failed for "
                            + "\(draft.id); returning compiled candidates to curation errorKind="
                            + String(reflecting: type(of: error))
                    )
                } else if case .evaluateSources = work {
                    if let currentDraft = currentEvaluationDraft(
                        id: draft.id,
                        context: context
                    ) {
                        recordGenerationFailure(on: currentDraft, error: error)
                    }
                } else {
                    recordGenerationFailure(on: draft, error: error)
                }
                if failedDuringInitialResearch == false {
                    print("[Ohia] ⚠ Compose generation failed for \(draft.id): \(String(reflecting: type(of: error)))")
                }
            }
            try context.save()
        }
        return processed
    }

    /// Persists a compose first-draft generation: appends a version, swaps in
    /// the send identity's signature, stamps the personalization basis, and
    /// flips the draft to `drafted`. The user's brief stays on
    /// `composeInstruction` so later revisions keep their grounding.
    @MainActor
    private func persistComposeGeneration(output: DraftOutput, draft: Draft, context: ModelContext) {
        Self.refreshPendingStyleControlDecision(on: draft, context: context, includingRegister: true)
        let withSignature = applyingComposeSignature(to: output.replyText, draft: draft, context: context)
        let trigger = (draft.revisions ?? []).isEmpty
            ? DraftRevisionTrigger.initial
            : DraftRevisionTrigger.regenerate
        ComposerDecisionHistoryPersistence.recordGenerationBasis(
            on: draft, writtenLanguageID: output.languageID)
        Self.clearRegenerationCoveredByFullPass(on: draft)
        appendRevision(
            to: draft,
            bodyText: withSignature,
            trigger: trigger,
            instruction: nil,
            styleRegisterID: output.styleRegisterID,
            styleControlSnapshot: output.styleControlSnapshot,
            reasoningContent: output.reasoningContent,
            reasoningContinuationFingerprint: output.reasoningContinuationFingerprint,
            reasoningPrompt: output.reasoningPrompt,
            generationBasisJSON: output.generationBasisJSON,
            context: context
        )
        draft.replyText = withSignature
        draft.bodyHTML = nil
        Self.applyWriterWindowUsage(output.writerWindowUsage, to: draft)
        draft.personalizationJSON = encodeJSON(output.personalization)
        draft.styleRegisterID = output.styleRegisterID
        draft.applyGeneratedStyleControlSnapshot(
            output.styleControlSnapshot,
            consumedDecisionID: output.consumedStyleDecisionID
        )
        // Drain only the pick this pass honored; a newer pick made
        // mid-generation stays pending for the next pass.
        if draft.pendingStyleRegisterID == output.styleRegisterID {
            draft.pendingStyleRegisterID = nil
        }
        // Language reconcile, mirroring `generateAndPersist`: a language
        // switch made while this pass ran means the body just persisted is
        // in a superseded language — the draft keeps owing a fresh pass.
        let selectedLanguage = DraftLanguage.familyID(for: draft.languageID)
        if selectedLanguage != nil, output.languageID != selectedLanguage {
            draft.stageRaw = DraftStage.generating
        } else {
            draft.stageRaw = DraftStage.drafted
        }
    }

    /// The deferred question-evaluation pass for a compose draft: the user
    /// curated the sources and pressed Continue, or resolved a round of the
    /// decision interview (stage `evaluatingSources` either way). Runs the
    /// next interview round against the brief + curated sources + decisions
    /// so far. Open questions route to `collectingAnswers`; an empty opening
    /// round routes directly to initial generation, while an empty follow-up
    /// leaves the completed interview at `collectingAnswers` so the user can
    /// add Draft guidance and explicitly generate.
    @MainActor
    private func evaluateComposeSources(
        for draft: Draft,
        context: ModelContext
    ) async throws -> QuestionEvaluationOutcome {
        let brief = (draft.composeInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return .completed(draft) }
        try persistPackedComposeSources(
            ComposerSourceCoding.decode(draft.sourcesJSON),
            on: draft
        )

        guard let inputs = try questionEvaluationInputs(
            for: draft,
            framing: .compose,
            context: context
        ) else {
            return .stale
        }
        return try await runQuestionEvaluation(
            for: draft,
            inputs: inputs,
            context: context
        )
    }

    /// Compose analogue of `ensureAutomaticSources`: seed recipient-keyed
    /// evidence only for rows that have never stored a source list. A non-nil
    /// `sourcesJSON` is user-curated, even when it contains only user-added
    /// sources or an empty list.
    @MainActor
    private func ensureComposeAutomaticSources(on draft: Draft, context: ModelContext) async throws {
        guard draft.sourcesJSON == nil else { return }
        let existing = ComposerSourceCoding.decode(draft.sourcesJSON)
        guard let recipient = ComposeAddressEncoding.decode(draft.composeToJSON).first,
              !recipient.isEmpty else { return }
        let correspondentCandidates = await ComposeSourceCompiler.mergingAutomaticSources(
            into: existing,
            accountID: draft.composeFromAccountID,
            recipientAddress: recipient,
            context: context,
            messagesProvider: messagesProvider,
            draftID: draft.id
        )
        try Self.requireActiveComposerTarget(draftID: draft.id, context: context)
        let semanticTagCandidates = ComposerSourceCompiler.semanticIntentSources(
            accountID: draft.composeFromAccountID,
            intentText: composeSemanticIntentText(for: draft),
            context: context
        )
        let candidates = dedupeSources(correspondentCandidates + semanticTagCandidates)
        let counterpart = ComposeSourceCompiler.recipientNameAndProfile(
            recipientAddress: recipient,
            context: context
        ).name
        let selected: [ComposerSource]
        if draft.isAutomaticSourceResearchPending {
            selected = candidates
        } else {
            let modelSelected = try selectComposeAutomaticSources(
                for: draft,
                counterpart: counterpart.isEmpty ? recipient : counterpart,
                candidates: candidates
            )
            try Self.requireActiveComposerTarget(draftID: draft.id, context: context)
            selected = dedupeSources(
                modelSelected + candidates.filter { $0.kind == .messages }
            )
        }
        // A pending research pass first preserves the broad candidates for
        // selection against the completed brief. Otherwise, persist an empty
        // selection too: nil means selection has never run, while [] means
        // the candidates were evaluated and none materially helped.
        try persistPackedComposeSources(selected, on: draft)
    }

    /// Applies the compose draft's resolved signature slot (plain text
    /// only — the rich upgrade happens at the Composer's MainActor seams)
    /// to freshly generated body text. Returns the text unchanged when the
    /// draft is unsigned.
    @MainActor
    private func applyingComposeSignature(to text: String, draft: Draft, context: ModelContext) -> String {
        guard let accountID = draft.composeFromAccountID else { return text }
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
        descriptor.fetchLimit = 1
        guard let account = (try? context.fetch(descriptor))?.first else { return text }
        guard let sig = SignatureSlotResolver.plainTextSignature(for: draft, account: account) else {
            return text
        }
        return SignatureSwapper.swap(in: text, newSignature: sig)
    }

    // MARK: - Pass 3: queue intake

    @MainActor
    private func seedDraftsForNewMessages(
        context: ModelContext,
        budget: Int,
        priorityMessageID: UUID? = nil
    ) async throws -> Int {
        guard budget > 0 else { return 0 }

        // Target: explicitly queued non-Needs-Reply messages with analysis
        // but no persisted draft. Resolved Needs Reply messages remain
        // draft-less until Composer entry because their sources are prepared
        // by the background lane. The two narrow predicate fetches avoid
        // materializing the whole store
        // (10k–100k rows) on every pipeline tick; `requiresReply` stays
        // in-memory because pre-column legacy rows are NULL in SQL and a
        // `== true` predicate would drop them. The canonical eligibility
        // check filters the narrowed superset.
        let candidates = Self.queueCandidateMessages(
            context: context,
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        )
        // An older email of the conversation may still hold its pending
        // reply Draft (written by another process, so this context's
        // relationship can be stale); that Draft moves here, so no second one
        // is seeded meanwhile.
        let pending = candidates.filter { msg in
            msg.isComposerQueueEligible(automaticTriageQueueingEnabled: automaticTriageQueueingEnabled)
                && msg.analysis != nil
                && msg.draft == nil
                && !ReplySourcePreparationEligibility.isEligible(
                    msg,
                    context: context
                )
                && ReplySourcePreparationEligibility.otherEmailHoldingUnsentReplyDraft(
                    for: msg,
                    context: context
                ) == nil
        }

        let pendingNewestFirst = pending.sorted(by: Message.newestPipelineFirst)
        let ordered = Self.priorityFirst(
            pendingNewestFirst,
            priorityMessageID: priorityMessageID,
            messageID: { $0.id }
        )
        let batch = Array(ordered.prefix(budget))
        var processed = 0

        for message in batch {
            let messageID = message.id
            let snapshot = try await replySourceCompiler.compile(
                for: message,
                context: context,
                preservingUserAddedSources: []
            )
            do {
                try Self.requireActiveComposerTarget(
                    messageID: messageID,
                    context: context
                )
            } catch is CancellationError {
                continue
            }
            if try seedSourceStageDraft(
                for: messageID,
                snapshot: snapshot,
                context: context
            ) {
                processed += 1
            }
        }
        return processed
    }

    // MARK: - Pass 2.5: source evaluations

    /// Runs the deferred question-evaluation pass for reply drafts at
    /// `evaluatingSources` — entered automatically after source compilation for
    /// explicit queue intake, by Re-check, or after resolving a question round.
    /// Routes the draft to `collectingAnswers` when decisions remain open or
    /// an answered interview is complete. Only an empty opening evaluation
    /// advances directly to generation. Engine failures leave the draft at
    /// `evaluatingSources` under backoff so a transient outage retries rather
    /// than silently drafting.
    @MainActor
    private func processSourceEvaluations(
        context: ModelContext,
        budget: Int,
        priorityMessageID: UUID? = nil
    ) async throws -> Int {
        guard budget > 0 else { return 0 }
        let now = Date()
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        let owedByAge = drafts.filter { draft in
            draft.kind != .userCompose
                && draft.status == .pending
                && draft.message != nil
                && Self.isEligibleForAttempt(draft, now: now)
                && draft.resolvedStage == DraftStage.evaluatingSources
        }
        .sorted { $0.generatedAt < $1.generatedAt }
        let owed = Self.priorityFirst(
            owedByAge,
            priorityMessageID: priorityMessageID,
            messageID: { $0.message?.id }
        )

        var processed = 0
        for draft in owed.prefix(budget) {
            guard let message = draft.message else { continue }
            do {
                let outcome = try await evaluateReplySources(
                    for: message,
                    draft: draft,
                    context: context
                )
                switch outcome {
                case .completed(let currentDraft):
                    clearGenerationFailure(on: currentDraft)
                    processed += 1
                case .stale:
                    processed += 1
                case .alreadyInFlight:
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ComposerContextPackingError {
                if let currentDraft = currentEvaluationDraft(
                    id: draft.id,
                    context: context
                ) {
                    holdOversizedContext(
                        on: currentDraft,
                        framing: "Reply",
                        error: error
                    )
                }
            } catch {
                // Infrastructure failure (model unloaded, backpressure
                // cancellation) — NOT "no questions needed". Keep the draft at
                // `evaluatingSources` under backoff so the reseed retries.
                if let currentDraft = currentEvaluationDraft(
                    id: draft.id,
                    context: context
                ) {
                    recordGenerationFailure(on: currentDraft, error: error)
                }
                #if DEBUG
                questionPreparationLogger.error("Source evaluation failed draft=\(draft.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                #else
                questionPreparationLogger.error("Source evaluation failed errorKind=\(String(reflecting: type(of: error)), privacy: .public)")
                #endif
            }
        }
        return processed
    }

    /// Runs the next interview round for a reply draft from its curated
    /// sources and the decisions made so far. When no question generator is
    /// wired (tests, degraded engine states) the evaluation degrades to "no
    /// questions" and starts the draft immediately rather than stranding.
    @MainActor
    private func evaluateReplySources(
        for message: Message,
        draft: Draft,
        context: ModelContext
    ) async throws -> QuestionEvaluationOutcome {
        try persistPackedReplySources(
            ComposerSourceCoding.decode(draft.sourcesJSON),
            on: draft,
            message: message
        )
        guard let inputs = try questionEvaluationInputs(
            for: draft,
            framing: .reply,
            context: context
        ) else {
            return .stale
        }
        return try await runQuestionEvaluation(
            for: draft,
            inputs: inputs,
            context: context
        )
    }

    @MainActor
    private func performInitialComposeResearch(
        on draft: Draft,
        context: ModelContext
    ) async throws -> Bool {
        guard draft.isAutomaticSourceResearchPending else { return true }
        let initialInputFingerprint = ComposerResearchInputFingerprint.value(
            for: draft,
            brief: draft.composeInstruction ?? ""
        )
        let initialStage = draft.resolvedStage
        guard initialComposeResearchIsCurrent(
            draftID: draft.id,
            inputFingerprint: initialInputFingerprint,
            stage: initialStage,
            context: context
        ) else {
            return false
        }
        // Make the current source frame durable before selector/website work
        // can overlap an app-process edit. A later stale return then leaves
        // this context clean and cannot re-save old candidates over the app's
        // newer row.
        try context.save()
        let existing = ComposerSourceCoding.decode(draft.sourcesJSON)
        let userAdded = existing.filter(\.isUserAdded)
        let compiled = await composeAutomaticSourceCandidates(
            for: draft,
            context: context
        )
        let candidates = dedupeSources(
            existing.filter { !$0.isUserAdded } + compiled.all
        )
        let recipient = ComposeAddressEncoding.decode(draft.composeToJSON).first ?? ""
        let counterpart = ComposeSourceCompiler.recipientNameAndProfile(
            recipientAddress: recipient,
            context: context
        ).name
        let selected: [ComposerSource]
        do {
            selected = try selectComposeAutomaticSources(
                for: draft,
                counterpart: counterpart.isEmpty ? recipient : counterpart,
                structuralCandidates: compiled.correspondent,
                candidates: candidates
            )
        } catch {
            guard initialComposeResearchIsCurrent(
                draftID: draft.id,
                inputFingerprint: initialInputFingerprint,
                stage: initialStage,
                context: context
            ) else {
                return false
            }
            // Preserve the deterministic compilation so the generic failure
            // path can unlock Composer with a usable list.
            try persistPackedComposeSources(
                dedupeSources(candidates + userAdded),
                on: draft
            )
            throw error
        }
        let requiredMessages = compiled.all.filter { $0.kind == .messages }
        let selectedLocal = dedupeSources(selected + requiredMessages + userAdded)
        guard initialComposeResearchIsCurrent(
            draftID: draft.id,
            inputFingerprint: initialInputFingerprint,
            stage: initialStage,
            context: context
        ) else {
            return false
        }
        var recoverableLocalSources = selectedLocal
        let withLocalPages: [ComposerSource]
        let researched: [ComposerSource]
        do {
            withLocalPages = try await automaticWebsiteSourceExpander(selectedLocal)
            recoverableLocalSources = withLocalPages
            researched = try await externalResearchSources(
                for: composeResearchContext(
                    draft: draft,
                    context: context,
                    sources: withLocalPages,
                    decisions: []
                ),
                phase: .initial
            )
        } catch {
            guard initialComposeResearchIsCurrent(
                draftID: draft.id,
                inputFingerprint: initialInputFingerprint,
                stage: initialStage,
                context: context
            ) else {
                return false
            }
            // On a current-pass infrastructure failure, expose the most
            // complete deterministic local selection before the generic
            // recovery path unlocks curation. Never write it after the app
            // has changed the addressed message frame while an await was in
            // flight.
            try persistPackedComposeSources(recoverableLocalSources, on: draft)
            throw error
        }
        guard initialComposeResearchIsCurrent(
            draftID: draft.id,
            inputFingerprint: initialInputFingerprint,
            stage: initialStage,
            context: context
        ) else {
            print(
                "[Ohia] Initial compose source research discarded after "
                    + "recipient/subject state changed for \(draft.id)"
            )
            return false
        }
        try persistPackedComposeSources(
            dedupeSources(withLocalPages + researched + requiredMessages),
            on: draft
        )
        draft.completeAutomaticSourceResearch()
        return true
    }

    @MainActor
    private func initialComposeResearchIsCurrent(
        draftID: UUID,
        inputFingerprint: String,
        stage: String,
        context: ModelContext
    ) -> Bool {
        let authoritativeContext = ModelContext(context.container)
        let predicate = #Predicate<Draft> { $0.id == draftID }
        guard let authoritative = try? authoritativeContext.fetch(
            FetchDescriptor<Draft>(predicate: predicate)
        ).first else {
            return false
        }
        return authoritative.status == .pending
            && authoritative.isAutomaticSourceResearchPending
            && authoritative.resolvedStage == stage
            && (authoritative.automaticSourceResearchInputFingerprint == nil
                || authoritative.automaticSourceResearchInputFingerprint == inputFingerprint)
            && ComposerResearchInputFingerprint.value(
                for: authoritative,
                brief: authoritative.composeInstruction ?? ""
            ) == inputFingerprint
    }

    @MainActor
    private func replyResearchContext(
        message: Message,
        cleanedBody: String,
        sources: [ComposerSource],
        decisions: [String]
    ) -> ComposerWebResearchContext {
        ComposerWebResearchContext(
            framing: .reply,
            subject: message.subject,
            bodyOrBrief: cleanedBody,
            counterpart: message.fromName ?? message.fromAddress,
            knownContextDigest: sources.promptDigest(perSourceLimit: 600, totalLimit: 5_000),
            decisionsDigest: decisions.joined(separator: "\n")
        )
    }

    @MainActor
    private func composeResearchContext(
        draft: Draft,
        context: ModelContext,
        sources: [ComposerSource],
        decisions: [String]
    ) -> ComposerWebResearchContext {
        let recipient = ComposeAddressEncoding.decode(draft.composeToJSON).first ?? ""
        let counterpart = ComposeSourceCompiler.recipientNameAndProfile(
            recipientAddress: recipient,
            context: context
        ).name
        return ComposerWebResearchContext(
            framing: .compose,
            subject: draft.composeSubject ?? "",
            bodyOrBrief: draft.composeInstruction ?? "",
            counterpart: counterpart.isEmpty ? recipient : counterpart,
            knownContextDigest: sources.promptDigest(perSourceLimit: 600, totalLimit: 5_000),
            decisionsDigest: decisions.joined(separator: "\n")
        )
    }

    @MainActor
    private func composeAutomaticSourceCandidates(
        for draft: Draft,
        context: ModelContext
    ) async -> (all: [ComposerSource], correspondent: [ComposerSource]) {
        var seenRecipients = Set<String>()
        let recipients = (
            ComposeAddressEncoding.decode(draft.composeToJSON)
                + ComposeAddressEncoding.decode(draft.composeCcJSON)
                + ComposeAddressEncoding.decode(draft.composeBccJSON)
        ).compactMap { address -> String? in
            let normalized = address
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalized.isEmpty == false,
                  seenRecipients.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }

        var correspondentSources: [ComposerSource] = []
        for recipient in recipients {
            correspondentSources.append(contentsOf: await ComposeSourceCompiler.compile(
                accountID: draft.composeFromAccountID,
                recipientAddress: recipient,
                context: context,
                messagesProvider: messagesProvider,
                draftID: draft.id
            ))
        }
        let subjectMemorySources = composeSubjectMemorySources(
            for: draft,
            recipients: recipients,
            excluding: correspondentSources,
            context: context
        )
        let semanticTagSources = ComposerSourceCompiler.semanticIntentSources(
            accountID: draft.composeFromAccountID,
            intentText: composeSemanticIntentText(for: draft),
            context: context
        )
        let localSources = dedupeSources(
            correspondentSources + subjectMemorySources + semanticTagSources
        )
        let retrievalSources = composeRetrievalSourceCandidates(
            for: draft,
            recipients: recipients,
            contextSources: localSources,
            context: context
        )
        return (
            all: dedupeSources(localSources + retrievalSources),
            correspondent: dedupeSources(correspondentSources)
        )
    }

    private func composeSemanticIntentText(for draft: Draft) -> String {
        [draft.composeSubject, draft.composeInstruction]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    @MainActor
    private func composeSubjectMemorySources(
        for draft: Draft,
        recipients: [String],
        excluding existing: [ComposerSource],
        context: ModelContext
    ) -> [ComposerSource] {
        guard let accountID = draft.composeFromAccountID else { return [] }
        let subject = (draft.composeSubject ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard subject.isEmpty == false else { return [] }
        let query = ([subject] + recipients).joined(separator: "\n")
        let memoryContext = try? StoredAccountMemoryProvider(
            container: context.container
        ).context(
            for: query,
            filter: FilterSpec(
                accountIds: [accountID],
                senderEmails: recipients
            ),
            limit: AskMemoryLimit(maxSnippets: 8, maxCharacters: 1_600)
        )
        let existingMemoryText = Set(existing.lazy.filter {
            $0.kind == .memory
        }.map {
            $0.snippet
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .lowercased()
        })
        return (memoryContext?.snippets ?? []).compactMap { note in
            let normalized = note.text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .lowercased()
            guard existingMemoryText.contains(normalized) == false else {
                return nil
            }
            guard let status = note.statusRaw,
                  let kind = note.kindRaw,
                  let basis = note.formationBasisRaw,
                  let policy = note.usePolicyRaw,
                  let futureUse = note.futureUseText else {
                return nil
            }
            let memoryNote = MemoryNote(
                dimensionLabel: note.title,
                text: note.text,
                status: status,
                weight: note.score,
                kindRaw: kind,
                formationBasisRaw: basis,
                usePolicyRaw: policy,
                futureUseText: futureUse
            )
            return ComposerSource(
                kind: .memory,
                label: note.title,
                snippet: MemoryNoteRendering.line(for: memoryNote)
            )
        }
    }

    @MainActor
    private func composeRetrievalSourceCandidates(
        for draft: Draft,
        recipients: [String],
        contextSources: [ComposerSource],
        context: ModelContext
    ) -> [ComposerSource] {
        guard let hybridRetriever,
              let accountID = draft.composeFromAccountID else {
            return []
        }
        let subject = (draft.composeSubject ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard subject.isEmpty == false else { return [] }
        let query = """
        Subject: \(subject)
        Recipients: \(recipients.joined(separator: " · "))
        """
        let filter = FilterSpec(
            accountIds: [accountID],
            collections: [.context, .attachment]
        )
        let budget = AskPromptBudget(
            directMessageLimit: 1,
            wideMessageLimit: 500,
            wideSourceLimit: 32,
            standardSourceLimit: 32,
            directSourceLimit: 32
        )
        let results = (try? hybridRetriever.retrieveForAsk(
            query: query,
            filter: filter,
            budget: budget
        ).sources) ?? []
        let excludedMessageIDs = Set(contextSources.compactMap(\.messageID))
        let anchorTerms = ComposerSourceRelevance.tokens(
            query,
            maxTokens: 160
        ).sorted()
        var seen = Set<String>()
        return results.compactMap { result in
            guard let messageID = UUID(uuidString: result.record.messageId),
                  excludedMessageIDs.contains(messageID) == false,
                  let hydrated = fetchMessage(id: messageID, context: context) else {
                return nil
            }
            let key = "\(messageID.uuidString)\u{1f}\(result.record.collection.rawValue)"
            guard seen.insert(key).inserted else { return nil }
            return retrievalSource(
                from: result,
                messageID: messageID,
                hydrated: hydrated,
                anchorTerms: anchorTerms
            )
        }
    }

    /// Plans focused queries from the complete local message/brief context,
    /// sends only the privacy-filtered query strings to MCP, and expands
    /// snippet-only web hits to one-page evidence. Failures contribute no
    /// sources and never block the draft pipeline.
    @MainActor
    private func externalResearchSources(
        for researchContext: ComposerWebResearchContext,
        phase: ComposerWebResearchPhase,
        expandWebsiteSources: Bool = true
    ) async throws -> [ComposerSource] {
        guard let webResearchPlanner, let externalResearchProvider else { return [] }
        switch ComposerWebResearchGate.evaluate(researchContext) {
        case .skip:
            return []
        case .allow:
            break
        }
        let needs: [ComposerWebResearchNeed]
        do {
            needs = try webResearchPlanner.researchNeeds(for: researchContext, phase: phase)
        } catch {
            print("[Ohia] Web research planning failed: \(String(reflecting: type(of: error)))")
            return []
        }
        guard !needs.isEmpty else { return [] }
        let sources = await externalResearchProvider.sources(for: needs)
        let forExpansion = ComposerWebSourceKeeper.keepForExpansion(sources, needs: needs)
        guard !forExpansion.isEmpty else { return [] }
        // When the caller expands later (reply candidate compile), keep
        // URL-bearing snippet hits soft-filtered so WebRAG can recover them.
        guard expandWebsiteSources else { return forExpansion }
        let expanded = try await automaticWebsiteSourceExpander(forExpansion)
        return ComposerWebSourceKeeper.keep(expanded, needs: needs)
    }

    /// Performs at most one decision-conditioned research pass per immutable
    /// protocol/decision identity. Empty and failed outcomes are durable so a
    /// deterministic no-result case never retries automatically.
    @MainActor
    private func prepareDecisionResearchOverlay(
        on draft: Draft,
        message: Message?,
        context: ModelContext
    ) async throws -> Bool {
        guard let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON) else {
            draft.decisionResearchOverlayJSON = nil
            return true
        }
        let selectedSources = ComposerSourceCoding.decode(draft.sourcesJSON)
        let input = ComposerInterviewDraftInputCompiler.compile(
            state: state,
            framing: draft.kind == .userCompose ? .compose : .reply,
            selectedSources: selectedSources,
            draftGuidance: draft.draftingInstruction
        )
        guard !input.acceptedDecisions.isEmpty,
              webResearchPlanner != nil,
              externalResearchProvider != nil else {
            draft.decisionResearchOverlayJSON = nil
            return true
        }

        let identity = ComposerDecisionResearchOverlayIdentity(
            inputFingerprint: state.inputFingerprint,
            decisionDigestFingerprint: input.acceptedDecisionDigestFingerprint,
            researchContractVersion: ComposerDecisionResearchOverlay.currentResearchContractVersion
        )
        if let existing = ComposerDecisionResearchOverlayCoding.decode(
            draft.decisionResearchOverlayJSON
        ), existing.isReusable(for: identity) {
            return true
        }
        draft.decisionResearchOverlayJSON = nil
        try context.save()

        let researchContext: ComposerWebResearchContext
        if let message {
            researchContext = replyResearchContext(
                message: message,
                cleanedBody: ComposerSourceRelevance.cleanedBodyText(for: message) ?? "",
                sources: selectedSources,
                decisions: input.userDecisionLines
            )
        } else {
            researchContext = composeResearchContext(
                draft: draft,
                context: context,
                sources: selectedSources,
                decisions: input.userDecisionLines
            )
        }

        let overlay: ComposerDecisionResearchOverlay
        do {
            let researched = try await externalResearchSources(
                for: researchContext,
                phase: .followUp
            )
            overlay = ComposerDecisionResearchOverlay(
                identity: identity,
                outcome: researched.isEmpty ? .empty : .populated,
                sources: dedupeSources(researched)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            overlay = ComposerDecisionResearchOverlay(
                identity: identity,
                outcome: .failed,
                sources: []
            )
        }

        try Self.requireActiveComposerTarget(
            draftID: draft.id,
            messageID: message?.id,
            context: context
        )
        guard let current = Self.storedDraft(id: draft.id, context: context),
              current.status == .pending,
              current.resolvedStage == DraftStage.generating,
              let currentState = ComposerInterviewStateCoding.decode(
                  current.interviewStateJSON
              ) else {
            return false
        }
        let currentInput = ComposerInterviewDraftInputCompiler.compile(
            state: currentState,
            framing: current.kind == .userCompose ? .compose : .reply,
            selectedSources: ComposerSourceCoding.decode(current.sourcesJSON),
            draftGuidance: current.draftingInstruction
        )
        let currentIdentity = ComposerDecisionResearchOverlayIdentity(
            inputFingerprint: currentState.inputFingerprint,
            decisionDigestFingerprint: currentInput.acceptedDecisionDigestFingerprint,
            researchContractVersion: ComposerDecisionResearchOverlay.currentResearchContractVersion
        )
        guard currentIdentity == identity else { return false }
        current.decisionResearchOverlayJSON = ComposerDecisionResearchOverlayCoding.encode(overlay)
        return true
    }

    @MainActor
    private func selectComposeAutomaticSources(
        for draft: Draft,
        counterpart: String,
        structuralCandidates: [ComposerSource] = [],
        candidates: [ComposerSource]
    ) throws -> [ComposerSource] {
        guard !candidates.isEmpty else { return [] }
        guard let sourceSelector else {
            throw ComposeSourceSelectionError.selectorUnavailable
        }
        return try sourceSelector.selectSources(
            forComposeBrief: draft.composeInstruction ?? "",
            subject: draft.composeSubject ?? "",
            recipient: counterpart,
            structuralSources: structuralCandidates,
            candidates: candidates
        )
    }

    @MainActor
    static func sourceRetrievalQueries(for message: Message) -> [String] {
        func nonempty(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = trimmed.lowercased()
                guard trimmed.isEmpty == false, seen.insert(key).inserted else {
                    return nil
                }
                return trimmed
            }
        }

        let evidenceMessages = [message] + (message.thread?.messages ?? []).filter {
            $0.id != message.id && $0.isAutomatedOrBulk != true
        }
        let dimensions = evidenceMessages.compactMap(ComposerSourceRelevance.dimensions(of:))
        let tags = nonempty(
            dimensions.flatMap { dimensions in
                SemanticTagProjectionPresentation.canonical(dimensions.semanticTags).map(\.displayName)
            }
        )
        let identifiers = ComposerSourceRelevance.distinctiveIdentifiers(
            in: evidenceMessages.reduce(into: Set<String>()) { terms, evidenceMessage in
                terms.formUnion(ComposerSourceRelevance.relevanceTerms(for: evidenceMessage))
            }
        ).sorted()
        let deadlines = nonempty(dimensions.flatMap { $0.deadlines.compactMap(\.displayText) })
        var tasks = evidenceMessages.flatMap(ComposerSourceRelevance.triageResearchTerms(of:))
        for evidenceMessage in evidenceMessages {
            guard let dimensions = ComposerSourceRelevance.dimensions(of: evidenceMessage) else {
                continue
            }
            for task in ComposerSourceRelevance.legacyTaskRequirements(
                of: evidenceMessage,
                dimensions: dimensions
            ) {
                tasks.append(task.taskType)
                tasks.append(task.actionObject ?? "")
                tasks.append(task.dueCandidate ?? "")
            }
        }
        tasks = nonempty(tasks)
        let summaryAndBody = nonempty(evidenceMessages.flatMap { evidenceMessage in
            [
                evidenceMessage.analysis?.bodySummary ?? "",
                ComposerSourceRelevance.messageText(
                    for: evidenceMessage,
                    bodyLimit: 2_200,
                    attachmentLimit: 500
                )
            ]
        })

        func field(_ label: String, _ values: [String]) -> String {
            "\(label): \(values.isEmpty ? "(none)" : values.joined(separator: " · "))"
        }

        let matter = [
            field("Subject", nonempty([message.subject])),
            field("Tags", tags),
            field("Identifiers", identifiers),
            field("Deadlines", deadlines),
            field("Tasks", tasks),
            field("Summary/body", summaryAndBody),
        ].joined(separator: "\n")

        let counterpartName = nonempty([message.fromName ?? ""]).first ?? message.fromAddress
        let counterpart = "\(counterpartName) <\(message.fromAddress)>"
        let strongestMatterIdentifiers = identifiers.isEmpty
            ? Array(evidenceMessages.reduce(into: Set<String>()) { terms, evidenceMessage in
                terms.formUnion(ComposerSourceRelevance.relevanceTerms(for: evidenceMessage))
            }.sorted().prefix(16))
            : Array(identifiers.prefix(16))
        let correspondent = [
            counterpart,
            field("Matter identifiers", strongestMatterIdentifiers),
            field("Subject", nonempty([message.subject])),
            field("Tags", tags),
        ].joined(separator: "\n")

        return [
            String(matter.prefix(5_000)),
            String(correspondent.prefix(2_000)),
        ]
    }

    static func mergeRetrievalLanes<Element>(
        _ lanes: [[Element]],
        excludingMessageIDs: Set<UUID> = [],
        messageID: (Element) -> UUID
    ) -> [Element] {
        var seenMessageIDs = excludingMessageIDs
        var merged: [Element] = []
        for lane in lanes {
            for hit in lane {
                guard seenMessageIDs.insert(messageID(hit)).inserted else { continue }
                merged.append(hit)
            }
        }
        return merged
    }

    static func qualifiedRetrievalHits<Element>(
        _ hits: [Element],
        relevanceScores: [UUID: Double],
        limit: Int = Int.max,
        messageID: (Element) -> UUID
    ) -> [Element] {
        guard limit > 0 else { return [] }
        var qualified: [Element] = []
        for hit in hits where relevanceScores[messageID(hit)] != nil {
            qualified.append(hit)
            if qualified.count == limit { break }
        }
        return qualified
    }

    /// Builds the source for one qualified retrieval hit. Message-backed hits
    /// carry the hydrated `Message` row used by the hard affinity gate and the
    /// same direction-aware attribution as
    /// deterministically compiled sources ("you → <recipient>" for the
    /// user's own mail, "related · <sender>" for inbound) — the question
    /// and generation prompts rely on that attribution to keep the two
    /// correspondents' voices apart.
    @MainActor
    private func retrievalSource(
        from result: RetrievalResult,
        messageID: UUID,
        hydrated: Message,
        anchorTerms: [String]
    ) -> ComposerSource {
        let parsed = ComposerRetrievalPayload.parse(result.record.textPayload)
        let kind: ComposerSource.Kind
        let label: String
        switch result.record.collection {
        case .attachment:
            kind = .attachment
            label = "retrieved attachment · \(parsed.subject ?? parsed.title ?? "source")"
        default:
            (kind, label) = Self.retrievedMessageAttribution(
                hydrated: hydrated,
                parsed: parsed
            )
        }
        let snippet = Self.retrievalSnippet(
            collection: result.record.collection,
            parsedPayload: parsed,
            rawPayload: result.record.textPayload,
            hydratedBody: loadBody(message: hydrated),
            anchorTerms: anchorTerms
        )
        return ComposerSource(
            kind: kind,
            label: label,
            snippet: snippet,
            messageID: messageID
        )
    }

    private static let retrievalPassageSelector = ComposerPassageSelector()

    static func retrievalSnippet(
        collection: VectorCollection,
        parsedPayload: ComposerRetrievalPayload,
        rawPayload: String,
        hydratedBody: String,
        anchorTerms: [String]
    ) -> String {
        let parsedBody = parsedPayload.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceText: String
        if collection == .attachment {
            sourceText = parsedBody.isEmpty ? raw : parsedBody
        } else {
            let hydrated = hydratedBody
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if hydrated.isEmpty == false {
                sourceText = hydrated
            } else {
                sourceText = parsedBody.isEmpty ? raw : parsedBody
            }
        }
        return retrievalPassageSelector.select(
            from: sourceText,
            anchorTerms: anchorTerms
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kind + label for a message-collection retrieval hit. Hydrated rows
    /// carry the shared direction-aware attribution (user-sent hits become
    /// `.pastReply` with a "you →" label); dead rows (deleted between
    /// indexing and compile) fall back to the parsed payload's headers.
    @MainActor
    static func retrievedMessageAttribution(
        hydrated: Message?,
        parsed: ComposerRetrievalPayload
    ) -> (kind: ComposerSource.Kind, label: String) {
        if let hydrated {
            return (
                hydrated.isSentByUser ? .pastReply : .retrieved,
                ComposerSourceCompiler.relatedLabel(for: hydrated)
            )
        }
        let sender = parsed.from ?? "unknown sender"
        let subject = parsed.subject ?? parsed.title ?? "no subject"
        return (.retrieved, "related · \(sender) · \(subject)")
    }

    private func dedupeSources(_ sources: [ComposerSource]) -> [ComposerSource] {
        var indexByKey: [String: Int] = [:]
        var result: [ComposerSource] = []
        for source in sources {
            let key = sourceDedupeKey(source)
            if let existingIndex = indexByKey[key] {
                // A user's explicit source wins over an automatic rendering
                // of the same mailbox message.
                if source.isUserAdded, result[existingIndex].isUserAdded == false {
                    result[existingIndex] = source
                }
                continue
            }
            indexByKey[key] = result.count
            result.append(source)
        }
        return result
    }

    private func sourceDedupeKey(_ source: ComposerSource) -> String {
        if let messageID = source.messageID {
            return "message\u{1f}\(messageID.uuidString)"
        }
        return [
            source.kind.rawValue,
            source.filePath ?? "",
            source.label
        ].joined(separator: "\u{1f}")
    }

    @MainActor
    private func packReplyContext(
        for message: Message,
        sources: [ComposerSource]
    ) throws -> ComposerContextPack {
        try QuestionGroundingContextPacking.reply(
            message: message,
            bodyText: QuestionGroundingContextPacking.replyAnchorText(for: message),
            sources: sources,
            packer: contextPacker
        )
    }

    @MainActor
    private func packComposeContext(
        for draft: Draft,
        sources: [ComposerSource]
    ) throws -> ComposerContextPack {
        try QuestionGroundingContextPacking.compose(
            brief: draft.composeInstruction ?? "",
            subject: draft.composeSubject ?? "",
            recipient: ComposeAddressEncoding.decode(draft.composeToJSON).first ?? "",
            sources: sources,
            packer: contextPacker
        )
    }

    @MainActor
    @discardableResult
    private func persistPackedReplySources(
        _ sources: [ComposerSource],
        on draft: Draft,
        message: Message
    ) throws -> ComposerContextPack {
        let pack = try packReplyContext(for: message, sources: sources)
        if draft.sourcesJSON == nil
            || ComposerSourceCoding.decode(draft.sourcesJSON) != pack.sources {
            draft.sourcesJSON = ComposerSourceCoding.encode(pack.sources)
        }
        persistSourceContextUsage(pack, on: draft)
        return pack
    }

    @MainActor
    @discardableResult
    private func persistPackedComposeSources(
        _ sources: [ComposerSource],
        on draft: Draft
    ) throws -> ComposerContextPack {
        let pack = try packComposeContext(for: draft, sources: sources)
        if draft.sourcesJSON == nil
            || ComposerSourceCoding.decode(draft.sourcesJSON) != pack.sources {
            draft.sourcesJSON = ComposerSourceCoding.encode(pack.sources)
        }
        persistSourceContextUsage(pack, on: draft)
        return pack
    }

    @MainActor
    private static func recordUnavailableSourceContextMeasurement(on draft: Draft) {
        draft.sourceContextTokenCount = nil
        draft.sourceContextTokenLimit = ComposerWriterWindow.promptBudget
        draft.sourceContextFitJSON = nil
        draft.sourceContextMeasurementRequestedAt = nil
    }

    @MainActor
    private func persistSourceContextUsage(_ pack: ComposerContextPack, on draft: Draft) {
        refreshWriterWindowUsage(on: draft, selectedPack: pack)
        draft.sourceContextMeasurementRequestedAt = nil
    }

    /// Measures the draft's next generation with the writer fit itself: the
    /// same source list, pack and compile the writer uses. A draft with a
    /// generated body is next revised from the editor text and any pending
    /// instruction, so those enter the measurement as they enter the writer.
    /// The meter is the framed writer prompt with every selected source
    /// against the writer prompt budget; the detail names the sources the
    /// writer leaves out. An unchanged request keeps its measurement. A
    /// request that cannot compile keeps the budget with no count, which the
    /// app does not request again; a missing tokenizer clears the budget so
    /// the app requests the measurement again once the model is loaded.
    @MainActor
    private func refreshWriterWindowUsage(on draft: Draft, selectedPack: ComposerContextPack? = nil) {
        guard let context = draft.modelContext else { return }
        let sources = DraftOrchestrator.generationSources(
            for: draft,
            selected: ComposerSourceCoding.decode(draft.sourcesJSON)
        )
        let revisesBody = !draft.orderedRevisions.isEmpty
        let pendingInstruction = draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let pack: ComposerContextPack
            if let selectedPack, selectedPack.sources == sources {
                pack = selectedPack
            } else if draft.kind == .userCompose {
                pack = try packComposeContext(for: draft, sources: sources)
            } else if let message = draft.message {
                pack = try packReplyContext(for: message, sources: sources)
            } else {
                Self.recordUnavailableSourceContextMeasurement(on: draft)
                return
            }
            let usage = try ComposerGenerationRequestCompiler.writerWindowUsage(
                draft: draft,
                context: context,
                pack: pack,
                window: contextPacker.writerWindow,
                currentBody: revisesBody ? draft.replyText : nil,
                instruction: revisesBody && pendingInstruction?.isEmpty == false ? pendingInstruction : nil,
                previous: draft.sourceContextTokenCount == nil
                    ? nil : ComposerWriterWindowUsage.decode(draft.sourceContextFitJSON)
            )
            Self.applyWriterWindowUsage(usage, to: draft)
        } catch TrainingEngineError.modelNotLoaded {
            draft.sourceContextTokenCount = nil
            draft.sourceContextTokenLimit = nil
            draft.sourceContextFitJSON = nil
            print("[Ohia] Composer writer-window measurement deferred: the drafting model is not loaded")
        } catch {
            Self.recordUnavailableSourceContextMeasurement(on: draft)
            print("[Ohia] Composer writer-window measurement unavailable: \(String(reflecting: type(of: error)))")
        }
    }

    /// Persists the writer fit a measurement or generation produced. A nil
    /// usage (a generator without a writer window) leaves the measurement.
    @MainActor
    static func applyWriterWindowUsage(_ usage: ComposerWriterWindowUsage?, to draft: Draft) {
        guard let usage else { return }
        draft.sourceContextTokenCount = usage.promptTokens
        draft.sourceContextTokenLimit = usage.promptBudget
        draft.sourceContextFitJSON = usage.json
    }

    @MainActor
    private func holdOversizedContext(
        on draft: Draft,
        framing: String,
        error: ComposerContextPackingError
    ) {
        draft.stageRaw = DraftStage.evaluatingSources
        recordGenerationFailure(on: draft, error: error)
        contextPackingFailureHandler?(error)
        print(
            "[Ohia] ⚠ \(framing) source evaluation held for \(draft.id): "
                + "selected context exceeds the model budget"
        )
    }

    /// Dispatches exactly one operation from persisted interview state:
    /// plan, ground one evidence batch, repair one committed free-text answer,
    /// or return to deterministic local traversal/generation.
    @MainActor
    private func runQuestionEvaluation(
        for draft: Draft,
        inputs: QuestionEvaluationInputs,
        context: ModelContext
    ) async throws -> QuestionEvaluationOutcome {
        guard Self.draftsBeingGrounded.insert(draft.id).inserted else {
            return .alreadyInFlight
        }
        defer { Self.draftsBeingGrounded.remove(draft.id) }

        let persistedState = ComposerInterviewStateCoding.decode(draft.interviewStateJSON)

        // A committed free-text answer is authoritative work in progress. The
        // prepared interview can carry the preparation fingerprint until this
        // bounded repair completes, so repair it before treating a fingerprint
        // difference as a request to replace the interview.
        if let state = persistedState {
            let projection = ComposerInterviewExecutor.project(state)
            if let pending = projection.pendingRepairAnswer {
                guard let interviewRepairer else {
                    throw TrainingEngineError.modelNotLoaded
                }
                let request = try repairRequest(
                    for: pending,
                    state: state,
                    projection: projection,
                    inputs: inputs
                )
                try context.save()
                let snapshot = questionGroundingAwaitSnapshot(draft: draft, inputs: inputs)
                let result = try interviewRepairer.repair(request)
                do {
                    try Self.requireActiveComposerTarget(
                        draftID: draft.id,
                        messageID: inputs.associatedMessageID,
                        context: context
                    )
                } catch is CancellationError {
                    return .stale
                }
                guard let current = currentDraft(
                    matching: snapshot,
                    framing: inputs.framing,
                    context: context
                ) else { return .stale }
                let updated = try ComposerInterviewExecutor.recordRepair(
                    result,
                    answerFingerprint: pending.answerFingerprint,
                    in: state
                )
                current.decisionResearchOverlayJSON = nil
                return try publishInterviewState(
                    updated,
                    on: current,
                    currentInterviewFingerprint: inputs.inputFingerprint
                )
            }
        }

        if persistedState == nil || persistedState?.inputFingerprint != inputs.inputFingerprint
            || persistedState?.contractVersion != ComposerInterviewPlanner.contractVersion {
            guard let interviewPlanner else {
                throw TrainingEngineError.modelNotLoaded
            }
            let generationEpoch = (persistedState?.generationEpoch ?? 0) + 1
            let carriedDecisions = persistedState.map {
                ComposerInterviewDraftInputCompiler.compile(state: $0, framing: inputs.framing,
                    selectedSources: inputs.contextPack.sources, draftGuidance: inputs.draftGuidance).acceptedDecisions
            } ?? []
            let planningGuidance = (carriedDecisions.map(\.promptLine)
                + [inputs.draftGuidance].compactMap { $0 }).joined(separator: "\n")
            try context.save()
            let snapshot = questionGroundingAwaitSnapshot(draft: draft, inputs: inputs)
            let result: ComposerInterviewPlannerResult
            do {
                result = try interviewPlanner.planReading(ComposerInterviewPlannerInput(
                    contextPack: inputs.contextPack,
                    subject: inputs.subject,
                    userName: inputs.userName,
                    counterpartName: inputs.counterpartName,
                    framing: inputs.framing,
                    questionLanguage: inputs.questionLanguage,
                    recipients: inputs.recipients,
                    sendingIdentity: inputs.sendingIdentity,
                    inputFingerprint: inputs.inputFingerprint,
                    evidenceFingerprint: QuestionGroundingResolver.evidenceFingerprint(
                        contextPack: inputs.contextPack,
                        framing: inputs.framing,
                        subject: inputs.subject,
                        accountID: inputs.accountID,
                        languageIdentifier: inputs.languageIdentifier
                    ),
                    generationEpoch: generationEpoch,
                    draftGuidance: planningGuidance.isEmpty ? nil : planningGuidance
                ), reusing: persistedState?.replyContext?.incomingReading)
            } catch {
                guard currentDraft(matching: snapshot, framing: inputs.framing,
                                   context: context) != nil else { return .stale }
                throw error
            }
            do {
                try Self.requireActiveComposerTarget(
                    draftID: draft.id,
                    messageID: inputs.associatedMessageID,
                    context: context
                )
            } catch is CancellationError {
                return .stale
            }
            guard let current = currentDraft(
                matching: snapshot,
                framing: inputs.framing,
                context: context
            ) else { return .stale }
            guard result.plan.planningOutcome != .invalid else {
                throw ComposerContentError.invalidBrief(
                    result.metrics.validationFailureReason ?? "Source preparation returned an invalid result."
                )
            }
            current.decisionResearchOverlayJSON = nil
            var nextState = ComposerInterviewState(plan: result.plan)
            nextState.carriedDecisions = carriedDecisions.isEmpty ? nil : carriedDecisions
            return try publishInterviewState(
                nextState,
                on: current,
                currentInterviewFingerprint: inputs.inputFingerprint
            )
        }

        guard let state = persistedState else { return .stale }
        let projection = ComposerInterviewExecutor.project(state)

        if !projection.nodesNeedingGrounding.isEmpty {
            let resolved: [QuestionGrounding]
            if state.replyContext == nil, let resolver = questionGroundingResolver {
                try context.save()
                let snapshot = questionGroundingAwaitSnapshot(draft: draft, inputs: inputs)
                do {
                    resolved = try await resolver.ground(
                        questions: projection.nodesNeedingGrounding,
                        contextPack: inputs.contextPack,
                        framing: inputs.framing,
                        subject: inputs.subject,
                        accountID: inputs.accountID,
                        languageIdentifier: inputs.languageIdentifier,
                        cachedGroundings: state.groundings
                    )
                } catch {
                    guard currentDraft(matching: snapshot, framing: inputs.framing,
                                       context: context) != nil else { return .stale }
                    throw error
                }
                do {
                    try Self.requireActiveComposerTarget(
                        draftID: draft.id,
                        messageID: inputs.associatedMessageID,
                        context: context
                    )
                } catch is CancellationError {
                    return .stale
                }
                guard let current = currentDraft(
                    matching: snapshot,
                    framing: inputs.framing,
                    context: context
                ) else { return .stale }
                let normalized = ComposerInterviewGroundingNormalizer.normalize(
                    state: state,
                    resolved: state.groundings + resolved
                )
                return try publishInterviewState(
                    normalized,
                    on: current,
                    currentInterviewFingerprint: inputs.inputFingerprint
                )
            }
            let normalized = ComposerInterviewGroundingNormalizer.normalize(
                state: state,
                resolved: state.groundings
            )
            return try publishInterviewState(
                normalized,
                on: draft,
                currentInterviewFingerprint: inputs.inputFingerprint
            )
        }

        return try publishInterviewState(
            state,
            on: draft,
            currentInterviewFingerprint: inputs.inputFingerprint
        )
    }

    /// `currentInterviewFingerprint` is the interview input fingerprint of the
    /// inputs this evaluation just revalidated against the stored Draft.
    @MainActor
    private func publishInterviewState(
        _ state: ComposerInterviewState,
        on draft: Draft,
        currentInterviewFingerprint: String
    ) throws -> QuestionEvaluationOutcome {
        draft.interviewStateJSON = ComposerInterviewStateCoding.encode(state)
        // Findings and settled questions change what the writer fit keeps.
        refreshWriterWindowUsage(on: draft)
        let projection = ComposerInterviewExecutor.project(state)
        if state.planningOutcome == .empty {
            draft.stageRaw = DraftStage.generating
        } else if state.planningOutcome == .invalid {
            draft.stageRaw = DraftStage.collectingAnswers
        } else if projection.pendingRepairAnswer != nil
                    || !projection.nodesNeedingGrounding.isEmpty {
            draft.stageRaw = DraftStage.evaluatingSources
        } else {
            draft.stageRaw = DraftStage.collectingAnswers
        }

        if draft.resolvedStage != DraftStage.evaluatingSources,
           state.planningOutcome != .invalid {
            let history = ComposerDecisionHistoryPersistence.decode(draft.decisionHistoryJSON)
            let createsNewVersion = history?.versions.last?.interviewState.inputFingerprint
                != state.inputFingerprint
            ComposerDecisionHistoryPersistence.recordCompletedEvaluation(
                on: draft,
                createsNewVersion: createsNewVersion
            )
            if let context = draft.modelContext {
                _ = try Self.stageReplyPreparationCache(from: draft, context: context) {
                    currentInterviewFingerprint
                }
            }
        }
        return .completed(draft)
    }

    /// Recover a completed interview from a Draft created before its reusable
    /// preparation was retained. Never relabel stale work with today's inputs.
    @MainActor
    public static func cacheReplyPreparationIfCurrent(
        from draft: Draft,
        context: ModelContext
    ) throws -> ReplySourcePreparation? {
        guard draft.hasCompletedAutomaticSourceResearch,
              draft.resolvedStage != DraftStage.collectingSources,
              draft.resolvedStage != DraftStage.evaluatingSources,
              let message = draft.message else { return nil }
        return try stageReplyPreparationCache(from: draft, context: context) {
            storedReplyInterviewFingerprint(for: draft, message: message)
        }
    }

    /// The reply interview input fingerprint of the Draft's stored inputs in
    /// the current reading language, packed the way a preparation packs them.
    @MainActor
    private static func storedReplyInterviewFingerprint(
        for draft: Draft,
        message: Message
    ) -> String? {
        let body = ComposerSourceRelevance.cleanedBodyText(for: message) == nil
            ? "" : message.bodyTextPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        guard let pack = try? QuestionGroundingContextPacking.reply(
            message: message, bodyText: body, sources: ComposerSourceCoding.decode(draft.sourcesJSON)
        ) else { return nil }
        let account = message.account
        let identity = account?.identities.first { $0.id == draft.fromIdentityID }
            ?? account?.identities.first(where: \.isPrimary) ?? account?.identities.first
        return interviewInputFingerprint(
            draft: draft, contextPack: pack, framing: .reply,
            languageIdentifier: DraftLanguage.familyID(for: draft.languageID)
                ?? DraftLanguage.familyID(for: message.languageDetected) ?? "und",
            questionLanguage: ComposerQuestionLanguage.current(),
            sendingIdentity: identity?.address
        )
    }

    /// A preparation row is stamped with today's preparation fingerprint, so
    /// it may carry only an interview planned from today's inputs: one adopted
    /// from the current preparation, or one whose interview input fingerprint
    /// is `currentInterviewFingerprint`. Both cover the reading language, so
    /// questions written in another language are never cached as current.
    @MainActor
    private static func stageReplyPreparationCache(
        from draft: Draft,
        context: ModelContext,
        currentInterviewFingerprint: () -> String?
    ) throws -> ReplySourcePreparation? {
        guard draft.kind != .userCompose, let message = draft.message,
              draft.draftingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              draft.replyRecipientModeRaw == nil || draft.replyRecipientModeRaw == ReplyRecipientMode.reply.rawValue,
              draft.replyToAddressesJSON == nil,
              draft.replyCcAddressesJSON == nil,
              draft.replyBccAddressesJSON == nil,
              draft.fromIdentityID == nil || draft.fromIdentityID == IdentityResolver.resolveReplyIdentity(message: message)?.id,
              draft.languageID == nil || DraftLanguage.familyID(for: draft.languageID) == DraftLanguage.familyID(for: message.languageDetected),
              let sourcesJSON = draft.sourcesJSON,
              let sourceData = sourcesJSON.data(using: .utf8),
              (try? JSONDecoder().decode([ComposerSource].self, from: sourceData)) != nil,
              var state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON),
              state.contractVersion == ComposerInterviewPlanner.contractVersion,
              state.planningOutcome != .invalid,
              case let .ready(snapshot) = ReplyPreparationInputReadiness.evaluate(
                  message: message, context: context, forCompletedDraftCache: true
              )
        else { return nil }
        let messageID = message.id
        let existing = try context.fetch(FetchDescriptor<ReplySourcePreparation>(
            predicate: #Predicate<ReplySourcePreparation> { $0.messageId == messageID }
        ))
        guard !existing.contains(where: {
            $0.statusRaw == ReplySourcePreparationStatus.ready
                && $0.inputFingerprint == snapshot.fingerprint
                && $0.contractVersion == ReplySourcePreparationFingerprint.contractVersion
        }) else { return nil }
        guard state.inputFingerprint == snapshot.fingerprint
            || state.inputFingerprint == currentInterviewFingerprint() else { return nil }
        // The cache is the initial interview, independent of discarded answers.
        state.answers = []
        state.acceptedPatches = []
        let questionIDs = Set(state.baseProtocol.questionNodes.map(\.id))
        state.groundings.removeAll { !questionIDs.contains($0.questionID) }
        let projection = ComposerInterviewExecutor.project(state)
        guard projection.nodesNeedingGrounding.isEmpty else { return nil }
        let cached = ReplySourcePreparation(
            message: message,
            statusRaw: ReplySourcePreparationStatus.ready,
            inputFingerprint: snapshot.fingerprint,
            contractVersion: ReplySourcePreparationFingerprint.contractVersion,
            witnessedLiveThreadMessageIDsJSON: String(decoding: try JSONEncoder().encode(
                snapshot.witnessedLiveThreadMessageIDs.map(\.uuidString).sorted()
            ), as: UTF8.self),
            sourcesJSON: sourcesJSON,
            sourceThreadCoverageJSON: draft.sourceThreadCoverageJSON,
            interviewStateJSON: ComposerInterviewStateCoding.encode(state),
            questionCount: projection.currentNode == nil ? 0 : 1,
            sourceThreadCount: draft.sourceThreadCount,
            sourceContextTokenCount: draft.sourceContextTokenCount,
            sourceContextTokenLimit: draft.sourceContextTokenLimit,
            sourceContextFitJSON: draft.sourceContextFitJSON,
            preparedAt: .now
        )
        // Scalar ownership survives Draft deletion and its rollback independently.
        cached.message = nil
        context.insert(cached)
        return cached
    }

    /// A writer can be asked for a body while typed words still wait for
    /// their one repair: Generate commits the typed answer and generates in
    /// one step, and a regeneration or restyle can be queued behind it. That
    /// repair runs here, before any writer, so the body and the questions that
    /// remain follow what the words mean, and no answer stays pending under a
    /// written draft, where it would refuse every later answer. Questions the
    /// reading leaves open reach the writer as unknown; follow-ups the repair
    /// marks as evidence questions are asked of the author instead, since this
    /// pass makes no model call beyond the repair. The stage is left as is.
    @MainActor
    private func repairPendingTypedAnswer(
        on draft: Draft,
        framing: ComposerInterviewFraming,
        context: ModelContext
    ) throws {
        guard let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON) else { return }
        let projection = ComposerInterviewExecutor.project(state)
        guard let pending = projection.pendingRepairAnswer else { return }
        guard let interviewRepairer else {
            throw TrainingEngineError.modelNotLoaded
        }
        guard let inputs = try questionEvaluationInputs(for: draft, framing: framing, context: context) else {
            throw ComposerInterviewExecutionError.repairAnswerMissing(pending.answerFingerprint)
        }
        let request = try repairRequest(
            for: pending,
            state: state,
            projection: projection,
            inputs: inputs
        )
        let snapshot = DraftInputSnapshot(draft: draft)
        try context.save()
        try Self.requireCurrentDraftInputs(
            snapshot, draft: draft, context: context,
            acceptingNewerStyleDecision: true
        )
        let result = try interviewRepairer.repair(request)
        try Self.requireCurrentDraftInputs(
            snapshot, draft: draft, context: context,
            acceptingNewerStyleDecision: true
        )
        var updated = try ComposerInterviewExecutor.recordRepair(
            result,
            answerFingerprint: pending.answerFingerprint,
            in: state
        )
        if !ComposerInterviewExecutor.project(updated).nodesNeedingGrounding.isEmpty {
            updated = ComposerInterviewGroundingNormalizer.normalize(
                state: updated,
                resolved: updated.groundings
            )
        }
        draft.interviewStateJSON = ComposerInterviewStateCoding.encode(updated)
        draft.decisionResearchOverlayJSON = nil
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        try context.save()
    }

    private func repairRequest(
        for answer: ComposerInterviewAnswer,
        state: ComposerInterviewState,
        projection: ComposerInterviewProjection,
        inputs: QuestionEvaluationInputs
    ) throws -> ComposerInterviewRepairRequest {
        let nodes = (state.baseProtocol.nodes + state.acceptedPatches.flatMap(\.nodes))
            .reduce(into: [String: ComposerInterviewNode]()) { $0[$1.id] = $1 }
        // Where the interview continues is not known here: on a choice
        // question it follows the choice the repair reads the typed words as
        // meaning, never the pick.
        guard nodes[answer.nodeID] != nil else {
            throw ComposerInterviewExecutionError.repairAnswerMissing(answer.answerFingerprint)
        }
        let answeredPrefix = projection.transcript.compactMap(\.answer)
        let resolvedVariableIDs = Set(projection.transcript.compactMap(\.node.variableID))
        let existingQuestionNodeCount = Set(
            nodes.values.lazy.filter { $0.kind == .question }.map(\.id)
        ).count
        return ComposerInterviewRepairRequest(
            contextPack: inputs.contextPack,
            plan: ComposerInterviewPlan(
                schemaVersion: ComposerInterviewPlanner.schemaVersion,
                contractVersion: state.contractVersion,
                inputFingerprint: state.inputFingerprint,
                evidenceFingerprint: state.evidenceFingerprint,
                generationEpoch: state.generationEpoch,
                planningOutcome: state.planningOutcome,
                baseProtocol: state.baseProtocol,
                replyContext: state.replyContext,
                questionLanguageIdentifier: state.questionLanguageIdentifier
            ),
            acceptedPatches: state.acceptedPatches,
            answeredPrefix: answeredPrefix,
            priorGroundings: state.groundings,
            resolvedVariableIDs: resolvedVariableIDs,
            protocolFingerprint: protocolFingerprint(for: state),
            answeredPrefixFingerprint: stableFingerprint(answeredPrefix),
            triggerAnswer: answer,
            remainingTotalQuestionNodes: max(
                0,
                ComposerInterviewProtocolValidator.maximumQuestionNodes
                    - existingQuestionNodeCount
            ),
            remainingPathQuestionNodes: max(
                0,
                ComposerInterviewProtocolValidator.maximumPathQuestionNodes
                    - answeredPrefix.count
            ),
            // Follow-ups continue the interview in the language its questions
            // were planned in. A reading-language change is a re-check.
            questionLanguage: state.questionLanguageIdentifier.map(ComposerQuestionLanguage.recorded)
                ?? inputs.questionLanguage
        )
    }

    private struct ProtocolFingerprintPayload: Encodable {
        let baseProtocol: ComposerInterviewProtocol
        let acceptedPatches: [ComposerInterviewPatch]
    }

    private func protocolFingerprint(for state: ComposerInterviewState) -> String {
        stableFingerprint(ProtocolFingerprintPayload(
            baseProtocol: state.baseProtocol,
            acceptedPatches: state.acceptedPatches
        ))
    }

    private func stableFingerprint<Value: Encodable>(_ value: Value) -> String {
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func questionEvaluationInputs(
        for draft: Draft,
        framing: ComposerInterviewFraming,
        context: ModelContext
    ) throws -> QuestionEvaluationInputs? {
        switch framing {
        case .reply:
            guard draft.kind != .userCompose,
                  let message = draft.message else {
                return nil
            }
            let account = message.account
                ?? fetchAccount(id: message.accountID, context: context)
            let contextPack = try packReplyContext(
                for: message,
                sources: ComposerSourceCoding.decode(draft.sourcesJSON)
            )
            let recipientState = questionRecipientState(for: draft)
            let recipients = ReplyRecipientPolicy.effectiveRecipients(for: draft)
            let sendingIdentity = identityAddress(for: draft, account: account)
            let questionLanguage = ComposerQuestionLanguage.current()
            return QuestionEvaluationInputs(
                contextPack: contextPack,
                subject: message.subject,
                accountID: message.accountID ?? account?.id,
                languageIdentifier: DraftLanguage.familyID(for: draft.languageID)
                    ?? DraftLanguage.familyID(for: message.languageDetected)
                    ?? "und",
                questionLanguage: questionLanguage,
                userName: Self.interviewUserName(
                    account: account,
                    draftIdentityID: draft.fromIdentityID
                ),
                counterpartName: message.fromName ?? message.fromAddress,
                framing: framing,
                recipients: recipients.to + recipients.cc + recipients.bcc,
                sendingIdentity: sendingIdentity,
                draftGuidance: draft.draftingInstruction,
                inputFingerprint: Self.interviewInputFingerprint(
                    draft: draft,
                    contextPack: contextPack,
                    framing: framing,
                    languageIdentifier: DraftLanguage.familyID(for: draft.languageID)
                        ?? DraftLanguage.familyID(for: message.languageDetected)
                        ?? "und",
                    questionLanguage: questionLanguage,
                    sendingIdentity: sendingIdentity
                ),
                associatedMessageID: message.id,
                recipientState: recipientState,
                composeInstruction: nil,
                fromIdentityID: draft.fromIdentityID
            )

        case .compose:
            guard draft.kind == .userCompose else { return nil }
            let brief = (draft.composeInstruction ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !brief.isEmpty else { return nil }
            let recipient = ComposeAddressEncoding.decode(draft.composeToJSON).first ?? ""
            let counterpart = ComposeSourceCompiler.recipientNameAndProfile(
                recipientAddress: recipient,
                context: context
            )
            let recipientName = counterpart.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let account = fetchAccount(id: draft.composeFromAccountID, context: context)
            let contextPack = try packComposeContext(
                for: draft,
                sources: ComposerSourceCoding.decode(draft.sourcesJSON)
            )
            let languageIdentifier = DraftLanguage.familyID(for: draft.languageID)
                ?? RecipientDraftLanguageResolver.preferredLanguage(
                    accountID: draft.composeFromAccountID,
                    correspondentAddress: recipient,
                    context: context
                )
                ?? "und"
            let recipientState = questionRecipientState(for: draft)
            let sendingIdentity = identityAddress(for: draft, account: account)
            let questionLanguage = ComposerQuestionLanguage.current()
            return QuestionEvaluationInputs(
                contextPack: contextPack,
                subject: draft.composeSubject ?? "",
                accountID: draft.composeFromAccountID,
                languageIdentifier: languageIdentifier,
                questionLanguage: questionLanguage,
                userName: Self.interviewUserName(
                    account: account,
                    draftIdentityID: draft.fromIdentityID
                ),
                counterpartName: recipientName.isEmpty ? "the recipient" : recipientName,
                framing: framing,
                recipients: ComposeAddressEncoding.decode(draft.composeToJSON)
                    + ComposeAddressEncoding.decode(draft.composeCcJSON)
                    + ComposeAddressEncoding.decode(draft.composeBccJSON),
                sendingIdentity: sendingIdentity,
                draftGuidance: nil,
                inputFingerprint: Self.interviewInputFingerprint(
                    draft: draft,
                    contextPack: contextPack,
                    framing: framing,
                    languageIdentifier: languageIdentifier,
                    questionLanguage: questionLanguage,
                    sendingIdentity: sendingIdentity
                ),
                associatedMessageID: nil,
                recipientState: recipientState,
                composeInstruction: draft.composeInstruction,
                fromIdentityID: draft.fromIdentityID
            )
        }
    }

    @MainActor
    private func identityAddress(for draft: Draft, account: Account?) -> String? {
        if let identityID = draft.fromIdentityID,
           let identity = account?.identities.first(where: { $0.id == identityID }) {
            return identity.address
        }
        return account?.identities.first(where: \.isPrimary)?.address
            ?? account?.identities.first?.address
    }

    @MainActor
    static func interviewInputFingerprint(
        draft: Draft,
        contextPack: ComposerContextPack,
        framing: ComposerInterviewFraming,
        languageIdentifier _: String,
        questionLanguage: SummarizationTargetLanguage,
        sendingIdentity: String?,
        draftGuidance: String? = nil
    ) -> String {
        let fields = [
            // Output language affects the writer, not established facts or
            // the user's accepted decisions. Reuse preparation when only it
            // changes. The reading language is the text of every question.
            "composer-interview-input-v4",
            String(ComposerInterviewPlanner.contractVersion),
            questionLanguage.identifier,
            framing.rawValue,
            contextPack.anchorText,
            contextPack.digest,
            draft.message?.subject ?? draft.composeSubject ?? "",
            draft.replyRecipientModeRaw ?? "",
            draft.replyToAddressesJSON ?? "",
            draft.replyCcAddressesJSON ?? "",
            draft.replyBccAddressesJSON ?? "",
            draft.composeToJSON ?? "",
            draft.composeCcJSON ?? "",
            draft.composeBccJSON ?? "",
            draft.message?.accountID?.uuidString ?? draft.composeFromAccountID?.uuidString ?? "",
            draft.fromIdentityID?.uuidString ?? "",
            sendingIdentity ?? "",
            framing == .reply ? (draftGuidance ?? draft.draftingInstruction ?? "") : "",
            draft.sourcesJSON ?? "",
        ]
        let payload = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @MainActor
    private func questionRecipientState(for draft: Draft) -> QuestionRecipientState {
        QuestionRecipientState(
            replyModeRaw: draft.replyRecipientModeRaw,
            replyToJSON: draft.replyToAddressesJSON,
            replyCcJSON: draft.replyCcAddressesJSON,
            replyBccJSON: draft.replyBccAddressesJSON,
            composeToJSON: draft.composeToJSON,
            composeCcJSON: draft.composeCcJSON,
            composeBccJSON: draft.composeBccJSON
        )
    }

    @MainActor
    private func questionGroundingAwaitSnapshot(
        draft: Draft,
        inputs: QuestionEvaluationInputs
    ) -> QuestionGroundingAwaitSnapshot {
        QuestionGroundingAwaitSnapshot(
            draftID: draft.id,
            statusRawValue: draft.status.rawValue,
            stageRaw: draft.stageRaw,
            interviewStateJSON: draft.interviewStateJSON,
            sourcesJSON: draft.sourcesJSON,
            languageIdentifier: inputs.languageIdentifier,
            framingRawValue: inputs.framing.rawValue,
            accountID: inputs.accountID,
            subject: inputs.subject,
            evidenceFingerprint: QuestionGroundingResolver.evidenceFingerprint(
                contextPack: inputs.contextPack,
                framing: inputs.framing,
                subject: inputs.subject,
                accountID: inputs.accountID,
                languageIdentifier: inputs.languageIdentifier
            ),
            inputFingerprint: inputs.inputFingerprint,
            userName: inputs.userName,
            counterpartName: inputs.counterpartName,
            associatedMessageID: inputs.associatedMessageID,
            recipientState: inputs.recipientState,
            composeInstruction: inputs.composeInstruction,
            fromIdentityID: inputs.fromIdentityID
        )
    }

    @MainActor
    private func questionGroundingSnapshot(
        _ snapshot: QuestionGroundingAwaitSnapshot,
        matches draft: Draft,
        inputs: QuestionEvaluationInputs
    ) -> Bool {
        guard draft.id == snapshot.draftID,
              draft.status == .pending,
              draft.status.rawValue == snapshot.statusRawValue,
              draft.resolvedStage == DraftStage.evaluatingSources,
              draft.stageRaw == snapshot.stageRaw,
              draft.interviewStateJSON == snapshot.interviewStateJSON,
              draft.sourcesJSON == snapshot.sourcesJSON,
              inputs.languageIdentifier == snapshot.languageIdentifier,
              inputs.framing.rawValue == snapshot.framingRawValue,
              inputs.accountID == snapshot.accountID,
              inputs.subject == snapshot.subject,
              inputs.inputFingerprint == snapshot.inputFingerprint,
              inputs.userName == snapshot.userName,
              inputs.counterpartName == snapshot.counterpartName,
              inputs.associatedMessageID == snapshot.associatedMessageID,
              inputs.recipientState == snapshot.recipientState,
              inputs.composeInstruction == snapshot.composeInstruction,
              inputs.fromIdentityID == snapshot.fromIdentityID else {
            return false
        }
        return QuestionGroundingResolver.evidenceFingerprint(
            contextPack: inputs.contextPack,
            framing: inputs.framing,
            subject: inputs.subject,
            accountID: inputs.accountID,
            languageIdentifier: inputs.languageIdentifier
        ) == snapshot.evidenceFingerprint
    }

    @MainActor
    private func currentDraft(
        matching snapshot: QuestionGroundingAwaitSnapshot,
        framing: ComposerInterviewFraming,
        context: ModelContext
    ) -> Draft? {
        let authoritativeContext = ModelContext(context.container)
        guard let stored = Self.storedDraft(id: snapshot.draftID, context: authoritativeContext),
              let storedInputs = try? questionEvaluationInputs(
                  for: stored,
                  framing: framing,
                  context: authoritativeContext
              ),
              questionGroundingSnapshot(snapshot, matches: stored, inputs: storedInputs),
              let draft = Self.storedDraft(id: snapshot.draftID, context: context),
              let inputs = try? questionEvaluationInputs(
                  for: draft,
                  framing: framing,
                  context: context
              ),
              questionGroundingSnapshot(snapshot, matches: draft, inputs: inputs) else {
            questionGroundingStateSignposter.emitEvent(
                "staleDiscard",
                "status=discarded"
            )
            return nil
        }
        return draft
    }

    @MainActor
    private func currentEvaluationDraft(
        id: UUID,
        context: ModelContext
    ) -> Draft? {
        guard let draft = Self.storedDraft(id: id, context: context),
              draft.status == .pending,
              draft.resolvedStage == DraftStage.evaluatingSources else {
            return nil
        }
        return draft
    }

    /// Ensures the message carries an owed draft row (stage `generating`)
    /// stamped with the compiled sources, creating it when absent — through
    /// the store-keyed duplicate check, since the app process can be
    /// creating the same row. Direct-generation paths call this BEFORE
    /// `generateAndPersist` so the `[SOURCES]` section reaches the prompt.
    @MainActor
    @discardableResult
    private func ensureOwedDraftRow(
        for message: Message,
        sources: [ComposerSource],
        context: ModelContext
    ) -> Draft {
        if let existing = message.draft ?? Self.storedDraft(for: message.id, context: context) {
            if message.draft == nil {
                message.draft = existing
            }
            if existing.sourcesJSON == nil {
                existing.sourcesJSON = ComposerSourceCoding.encode(sources)
            }
            return existing
        }
        let draft = Draft(
            message: message,
            replyText: "",
            confidence: 0,
            sourceThreadCount: message.thread?.messages.count ?? 1,
            sourceExemplarCount: 0,
            styleMatch: 0
        )
        draft.stageRaw = DraftStage.generating
        draft.fromIdentityID = IdentityResolver.resolveReplyIdentity(message: message)?.id
        draft.signatureSlotID = message.account?.defaultSignatureSlot?.id
        draft.sourcesJSON = ComposerSourceCoding.encode(sources)
        context.insert(draft)
        message.draft = draft
        try? context.save()
        return draft
    }


    /// Two narrow predicate fetches that bound every queue-intake scan: live
    /// inbound mail (automatic candidates) plus explicit "Send to Composer"
    /// additions. Returns a deduplicated superset of queue-eligible rows;
    /// callers (intake here, pack preparation in the BGE worker, the
    /// Composer's queue pane) apply `isComposerQueueEligible` for the exact
    /// decision.
    public static func queueCandidateMessages(
        context: ModelContext,
        automaticTriageQueueingEnabled: Bool
    ) -> [Message] {
        (try? loadQueueCandidateMessages(
            context: context,
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        )) ?? []
    }

    /// Presentation refreshes must distinguish an unavailable store from an
    /// empty queue. This throwing reader is the canonical candidate scan.
    public static func loadQueueCandidateMessages(
        context: ModelContext,
        automaticTriageQueueingEnabled: Bool
    ) throws -> [Message] {
        let include = ComposerQueueOverride.include.rawValue
        let autoPredicate = #Predicate<Message> { msg in
            msg.liveDetectedAt != nil && msg.isSentByUser == false && msg.trashedAt == nil
        }
        let includePredicate = #Predicate<Message> { msg in
            msg.composerQueueOverrideRaw == include && msg.trashedAt == nil
        }
        let autoCandidates = automaticTriageQueueingEnabled
            ? try context.fetch(FetchDescriptor<Message>(predicate: autoPredicate))
            : []
        let includedCandidates = try context.fetch(FetchDescriptor<Message>(predicate: includePredicate))
        var seenIDs = Set<UUID>()
        var merged: [Message] = []
        for msg in autoCandidates + includedCandidates where seenIDs.insert(msg.id).inserted {
            merged.append(msg)
        }
        return merged
    }

    /// Creates the source-stage draft for a newly-queued message. No body text
    /// and no questions exist yet. Compiled queue intake advances directly to
    /// question evaluation without a separate source-review confirmation.
    @MainActor
    private func seedSourceStageDraft(
        for messageID: UUID,
        snapshot: ReplySourceCompilationSnapshot,
        context: ModelContext
    ) throws -> Bool {
        // Compilation suspends this MainActor method, so every intake premise
        // must be re-established from the store before creating the row.
        // Foreground Composer entry, triage/manual attention changes, and queue
        // removal all win over this late compilation result.
        guard let message = try Self.storedMessage(id: messageID, context: context),
              !message.isTrashed,
              message.isComposerQueueEligible(
                  automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
              ),
              message.analysis != nil,
              try Self.storedIntakeDraft(for: messageID, context: context) == nil,
              ReplySourcePreparationEligibility.isEligible(
                  message,
                  context: context
              ) == false,
              ReplySourcePreparationEligibility.otherEmailHoldingUnsentReplyDraft(
                  for: message,
                  context: context
              ) == nil else {
            return false
        }
        let draft = Draft(
            message: message,
            replyText: "",
            confidence: 0,
            sourceThreadCount: snapshot.sourceThreadCount,
            sourceExemplarCount: 0,
            styleMatch: 0
        )
        draft.stageRaw = DraftStage.evaluatingSources
        draft.sourcesJSON = snapshot.sourcesJSON
        draft.sourceThreadCoverageJSON = snapshot.threadCoverageJSON
        if webResearchPlanner != nil, externalResearchProvider != nil {
            draft.completeAutomaticSourceResearch()
        }

        // Resolve reply identity now so the Composer's From picker is
        // correct from the first step; stamp the account's default
        // signature slot for the same reason (the picker shows it).
        draft.fromIdentityID = IdentityResolver.resolveReplyIdentity(message: message)?.id
        draft.signatureSlotID = message.account?.defaultSignatureSlot?.id

        context.insert(draft)
        message.draft = draft
        // Persist immediately — the app process's duplicate-creation check can
        // only see this row once it reaches the store.
        try context.save()
        return true
    }

    // MARK: - Generation + persistence

    /// Generates body text for a single message and persists it: updates the
    /// existing question-stage draft when one exists, otherwise creates the
    /// draft row. Appends a `DraftRevision` so the Composer's version
    /// switcher sees every generation pass.
    @MainActor
    public func generateAndPersist(for message: Message, context: ModelContext) async throws {
        let initialDraftID = (message.draft ?? Self.storedDraft(
            for: message.id,
            context: context
        ))?.id
        let messageID = message.id
        var generationDraft: Draft?
        var generationInputs: DraftInputSnapshot?
        if let currentDraft = message.draft ?? Self.storedDraft(
            for: message.id,
            context: context
        ) {
            try repairPendingTypedAnswer(on: currentDraft, framing: .reply, context: context)
            guard try await prepareDecisionResearchOverlay(
                on: currentDraft,
                message: message,
                context: context
            ) else {
                throw CancellationError()
            }
            let inputs = DraftInputSnapshot(draft: currentDraft)
            try context.save()
            try Self.requireCurrentDraftInputs(inputs, draft: currentDraft, context: context)
            generationDraft = currentDraft
            generationInputs = inputs
        }
        let output: DraftOutput
        do {
            output = try await draftOrchestrator.generateDraft(for: message, context: context)
        } catch {
            if let generationDraft, let generationInputs {
                try Self.requireCurrentDraftInputs(
                    generationInputs, draft: generationDraft, context: context,
                    acceptingNewerStyleDecision: false
                )
            }
            throw error
        }
        if let generationDraft, let generationInputs {
            try Self.requireCurrentDraftInputs(generationInputs, draft: generationDraft, context: context)
        }
        try Self.requireActiveComposerTarget(
            draftID: initialDraftID,
            messageID: messageID,
            context: context
        )
        if let draft = message.draft ?? Self.storedDraft(for: message.id, context: context) {
            Self.refreshPendingStyleControlDecision(on: draft, context: context, includingRegister: true)
        }
        _ = Self.materializeReplyOutput(
            output,
            generatedAt: .now,
            sourceThreadCount: message.thread?.messages.count ?? 1,
            preparedSources: nil,
            message: message,
            context: context
        )
    }

    /// Adopts a body generated by the background preparation worker into the
    /// exact same Draft and revision persistence path as on-demand generation.
    @MainActor
    @discardableResult
    public static func materializePreparedReply(
        _ payload: PreparedReplyDraftPayload,
        preparation: ReplySourcePreparation,
        message: Message,
        context: ModelContext
    ) -> Draft {
        materializeReplyOutput(
            payload.output,
            generatedAt: payload.generatedAt,
            sourceThreadCount: payload.sourceThreadCount,
            preparedSources: PreparedMaterializationSources(
                sourcesJSON: preparation.sourcesJSON,
                threadCoverageJSON: preparation.sourceThreadCoverageJSON,
                interviewStateJSON: preparation.interviewStateJSON,
                tokenCount: preparation.sourceContextTokenCount,
                tokenLimit: preparation.sourceContextTokenLimit,
                fitJSON: preparation.sourceContextFitJSON
            ),
            message: message,
            context: context
        )
    }

    private struct PreparedMaterializationSources {
        let sourcesJSON: String?
        let threadCoverageJSON: String?
        let interviewStateJSON: String?
        let tokenCount: Int?
        let tokenLimit: Int?
        let fitJSON: String?
    }

    @MainActor
    private static func materializeReplyOutput(
        _ output: DraftOutput,
        generatedAt: Date,
        sourceThreadCount: Int,
        preparedSources: PreparedMaterializationSources?,
        message: Message,
        context: ModelContext
    ) -> Draft {
        let exemplarCount = output.styleExemplarCount
        let confidence = computeMaterializedConfidence(
            findingsCount: output.citations.count,
            gapsCount: output.gaps.count,
            replyText: output.replyText
        )
        let styleMatch = computeMaterializedStyleMatch(exemplarCount: exemplarCount)

        let draft: Draft
        if let existing = message.draft ?? Self.storedDraft(for: message.id, context: context) {
            draft = existing
            draft.replyText = output.replyText
            draft.confidence = confidence
            draft.sourceThreadCount = sourceThreadCount
            draft.sourceExemplarCount = exemplarCount
            draft.styleMatch = styleMatch
            draft.generatedAt = generatedAt
            if message.draft == nil {
                message.draft = existing
            }
        } else {
            draft = Draft(
                message: message,
                replyText: output.replyText,
                confidence: confidence,
                sourceThreadCount: sourceThreadCount,
                sourceExemplarCount: exemplarCount,
                styleMatch: styleMatch
            )
            draft.generatedAt = generatedAt
            draft.signatureSlotID = message.account?.defaultSignatureSlot?.id
            context.insert(draft)
            message.draft = draft
        }
        if let preparedSources {
            draft.sourcesJSON = preparedSources.sourcesJSON
            draft.sourceThreadCoverageJSON = preparedSources.threadCoverageJSON
            draft.interviewStateJSON = preparedSources.interviewStateJSON
            draft.sourceContextTokenCount = preparedSources.tokenCount
            draft.sourceContextTokenLimit = preparedSources.tokenLimit
            draft.sourceContextFitJSON = preparedSources.fitJSON
        }
        // The fit this generation actually used: Composer marks exactly the
        // sources the writer left out of this body.
        applyWriterWindowUsage(output.writerWindowUsage, to: draft)
        let draftingInstruction = draft.draftingInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Resolve reply identity (To/Cc match, fallback to primary) unless
        // the user already chose one in the Composer. Nil is tolerated —
        // legacy accounts may have no identities pre-migration; the
        // IdentityMigrationApplier seeds them on boot.
        if draft.fromIdentityID == nil {
            draft.fromIdentityID = IdentityResolver.resolveReplyIdentity(message: message)?.id
        }

        // Append the resolved slot's signature to the LLM-generated body so
        // the materialization lives on the draft (Mail.app-style). The LLM
        // prompt is untouched — it never sees the sig, so training +
        // regenerate-with-feedback stay clean.
        draft.replyText = applyingMaterializedSignature(
            to: draft.replyText,
            draft: draft,
            message: message
        )

        // Fresh model text is plain; the Composer's rich editor re-derives
        // its attributed content from it.
        draft.bodyHTML = nil

        // Resolve citation source labels (subject of the source message)
        let citationDTOs = output.citations.map { cite -> CitationDTO in
            let sourceLabel = resolveMaterializedSourceLabel(
                messageId: cite.sourceMessageId,
                context: context
            )
            return CitationDTO(
                claim: cite.claim,
                sourceMessageId: cite.sourceMessageId,
                sourceLabel: sourceLabel
            )
        }
        draft.citationsJSON = encodeMaterializedJSON(citationDTOs)

        let gapDTOs = output.gaps.map {
            GapDTO(description: $0.description, suggestedAction: $0.suggestedAction)
        }
        draft.gapsJSON = encodeMaterializedJSON(gapDTOs)

        let deliverableDTOs = output.deliverables.map {
            DeliverableDTO(filename: $0.filename, filePath: $0.filePath, sourceMessageId: $0.sourceMessageId)
        }
        draft.deliverablesJSON = encodeMaterializedJSON(deliverableDTOs)

        // Stamp the generation-time personalization basis so the Composer's
        // Style panel can show whether (and how much) training shaped this
        // reply without a second generation.
        draft.personalizationJSON = encodeMaterializedJSON(output.personalization)

        // Stamp the register that steered this pass. Drain the pending
        // picker choice only when it is the one this generation honored —
        // a pick the user made while the 20-40s generation ran must survive
        // to restyle on the next pass, not be silently clobbered.
        draft.styleRegisterID = output.styleRegisterID
        draft.applyGeneratedStyleControlSnapshot(
            output.styleControlSnapshot,
            consumedDecisionID: output.consumedStyleDecisionID
        )
        if draft.pendingStyleRegisterID == output.styleRegisterID {
            draft.pendingStyleRegisterID = nil
        }

        // A later full pass remains a regenerate, even when it carries user
        // guidance. Continuity replays that guidance without misclassifying
        // this fresh-generation output as revision-shaped training evidence.
        let trigger = (draft.revisions ?? []).isEmpty
            ? DraftRevisionTrigger.initial
            : DraftRevisionTrigger.regenerate
        ComposerDecisionHistoryPersistence.recordGenerationBasis(
            on: draft, writtenLanguageID: output.languageID)
        clearRegenerationCoveredByFullPass(on: draft)
        appendMaterializedRevision(
            to: draft,
            bodyText: draft.replyText,
            trigger: trigger,
            instruction: draftingInstruction?.isEmpty == false ? draftingInstruction : nil,
            styleRegisterID: output.styleRegisterID,
            styleControlSnapshot: output.styleControlSnapshot,
            reasoningContent: output.reasoningContent,
            reasoningContinuationFingerprint: output.reasoningContinuationFingerprint,
            reasoningPrompt: output.reasoningPrompt,
            generationBasisJSON: output.generationBasisJSON,
            context: context
        )

        // Language reconcile: the pass was pinned to the draft's language at
        // its start. If the user switched language while the 20-40s pass
        // ran, the body just persisted is in a superseded language — keep
        // the draft owing a generation so the reseed loop rewrites it,
        // instead of settling on `drafted` with a mislabeled body.
        let selectedLanguage = DraftLanguage.resolvedID(for: message)
        if selectedLanguage != nil, output.languageID != selectedLanguage {
            draft.stageRaw = DraftStage.generating
        } else {
            draft.stageRaw = DraftStage.drafted
        }

        // Consume the regeneration feedback now that a fresh draft has been
        // persisted. If the user rejects this one again, SendDispatcher
        // will repopulate the field with new feedback on the next pass.
        message.regenerationFeedback = nil
        draft.draftingInstruction = nil
        return draft
    }

    // MARK: - Shared helpers

    @MainActor
    private func publishRevisionPersonalization(
        _ output: DraftRevisionOutput,
        on draft: Draft,
        context: ModelContext
    ) {
        guard let generation = ComposerGenerationBasis.decode(output.generationBasisJSON)?.personalization else {
            return
        }
        let snapshot: PersonalizationSnapshot
        if let message = draft.message, draft.kind != .userCompose {
            snapshot = DraftOrchestrator.capturePersonalization(for: message, context: context,
                generation: generation)
        } else {
            snapshot = DraftOrchestrator.capturePersonalizationForCompose(
                recipientAddress: ComposeAddressEncoding.decode(draft.composeToJSON).first ?? "",
                context: context, generation: generation)
        }
        draft.personalizationJSON = encodeJSON(snapshot)
    }

    @MainActor
    private func appendRevision(
        to draft: Draft,
        bodyText: String,
        trigger: String,
        instruction: String?,
        styleRegisterID: UUID? = nil,
        styleControlSnapshot: StyleControlSnapshot? = nil,
        reasoningContent: String? = nil,
        reasoningContinuationFingerprint: String? = nil,
        reasoningPrompt: String? = nil,
        generationBasisJSON: String? = nil,
        context: ModelContext
    ) {
        Self.appendMaterializedRevision(
            to: draft,
            bodyText: bodyText,
            trigger: trigger,
            instruction: instruction,
            styleRegisterID: styleRegisterID,
            styleControlSnapshot: styleControlSnapshot,
            reasoningContent: reasoningContent,
            reasoningContinuationFingerprint: reasoningContinuationFingerprint,
            reasoningPrompt: reasoningPrompt,
            generationBasisJSON: generationBasisJSON,
            context: context
        )
    }

    @MainActor
    private static func appendMaterializedRevision(
        to draft: Draft,
        bodyText: String,
        trigger: String,
        instruction: String?,
        styleRegisterID: UUID? = nil,
        styleControlSnapshot: StyleControlSnapshot? = nil,
        reasoningContent: String? = nil,
        reasoningContinuationFingerprint: String? = nil,
        reasoningPrompt: String? = nil,
        generationBasisJSON: String? = nil,
        context: ModelContext
    ) {
        let generatedSourcesJSON = ComposerSourceCoding.encode(
            DraftOrchestrator.generationSources(
                for: draft,
                selected: ComposerSourceCoding.decode(draft.sourcesJSON)
            )
        )
        // Ancestry: the pass's input was the generated revision the live body
        // derived from; its output becomes the revision the live body is.
        let inputRevisionID = draft.baseRevisionID ?? draft.baseGeneratedRevision?.id
        let revision = DraftRevision(
            draft: draft,
            index: draft.nextRevisionIndex,
            bodyText: bodyText,
            triggerRaw: trigger,
            instruction: instruction,
            styleRegisterID: styleRegisterID,
            styleControlSnapshot: styleControlSnapshot,
            generatedSourcesJSON: generatedSourcesJSON,
            reasoningContent: reasoningContent,
            reasoningContinuationFingerprint: reasoningContinuationFingerprint,
            reasoningPrompt: reasoningPrompt,
            generationBasisJSON: generationBasisJSON,
            baseRevisionID: inputRevisionID
        )
        context.insert(revision)
        if draft.revisions == nil {
            draft.revisions = [revision]
        } else if draft.revisions?.contains(where: { $0.id == revision.id }) == false {
            draft.revisions?.append(revision)
        }
        draft.baseRevisionID = revision.id
        draft.generatedSourcesJSON = generatedSourcesJSON
        if reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           reasoningContinuationFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           let reasoningPrompt,
           reasoningPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            revision.reasoningContextFingerprint = DraftReasoningContextFingerprint.value(for: reasoningPrompt)
        }
    }

    private static func computeMaterializedConfidence(
        findingsCount: Int,
        gapsCount: Int,
        replyText: String
    ) -> Double {
        var confidence = 0.7
        confidence -= Double(gapsCount) * 0.08
        confidence += Double(findingsCount) * 0.03
        if replyText.split(whereSeparator: { $0.isWhitespace }).count < 12 {
            confidence -= 0.15
        }
        return min(0.95, max(0.35, confidence))
    }

    private static func computeMaterializedStyleMatch(exemplarCount: Int) -> Double {
        0.45 + 0.1 * min(Double(exemplarCount), 5.0)
    }

    @MainActor
    private static func applyingMaterializedSignature(
        to text: String,
        draft: Draft,
        message: Message
    ) -> String {
        guard let signature = SignatureSlotResolver.plainTextSignature(
            for: draft,
            account: message.account
        ) else {
            return text
        }
        return SignatureSwapper.swap(in: text, newSignature: signature)
    }

    @MainActor
    private static func resolveMaterializedSourceLabel(
        messageId: String,
        context: ModelContext
    ) -> String {
        guard let id = UUID(uuidString: messageId) else { return messageId }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first?.subject) ?? "source"
    }

    private static func encodeMaterializedJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Refreshes only the pending style decision from a new store context
    /// immediately after a suspending generation call. The worker context may
    /// otherwise hold the decision that built the prompt and overwrite a
    /// newer slider move saved by the app process.
    @MainActor
    static func refreshPendingStyleControlDecision(
        on draft: Draft,
        context: ModelContext,
        includingRegister: Bool = false
    ) {
        let freshContext = ModelContext(context.container)
        let draftID = draft.id
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.id == draftID }
        )
        descriptor.fetchLimit = 1
        guard let fresh = try? freshContext.fetch(descriptor).first else { return }
        draft.pendingStyleControlSnapshotJSON = fresh.pendingStyleControlSnapshotJSON
        if includingRegister {
            draft.pendingStyleRegisterID = fresh.pendingStyleRegisterID
        }
    }

    @MainActor
    private func styleControlSnapshot(
        for draft: Draft,
        registerID: UUID?,
        languageID: String?,
        includingPending: Bool,
        context: ModelContext
    ) -> StyleControlSnapshot? {
        let register = styleRegisterNote(
            registerID: registerID,
            languageID: languageID,
            context: context
        )
        return DraftOrchestrator.styleControlSnapshot(
            for: draft,
            register: register,
            includingPending: includingPending
        )
    }

    @MainActor
    private func styleRegisterNote(
        registerID: UUID?,
        languageID: String?,
        context: ModelContext
    ) -> StyleRegisterNote? {
        DraftOrchestrator.explicitRegister(
            id: registerID,
            language: languageID,
            context: context
        ).map(StyleRegisterResolver.note(from:))
    }

    /// Applies the reply draft's resolved signature slot (plain text only —
    /// the rich upgrade happens at the Composer's MainActor seams). Returns
    /// the text unchanged when the draft is unsigned.
    @MainActor
    private func applyingSignature(to text: String, draft: Draft, message: Message) -> String {
        guard let sig = SignatureSlotResolver.plainTextSignature(for: draft, account: message.account) else {
            return text
        }
        return SignatureSwapper.swap(in: text, newSignature: sig)
    }

    // MARK: - Helpers

    /// The user's name as the interview prompt states it, resolved from the
    /// identity the draft sends as (fallback: the account's primary
    /// identity). The interview binds this name against the "Hi <name>" /
    /// "Best, <name>" deixis inside the sources, so it must be the name
    /// correspondents actually address the user by.
    @MainActor
    static func interviewUserName(account: Account?, draftIdentityID: UUID?) -> String {
        guard let identity = account?.resolveIdentity(for: draftIdentityID) else {
            return "the user"
        }
        let name = identity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? identity.address : name
    }

    @MainActor
    private func fetchAccount(id: UUID?, context: ModelContext) -> Account? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    @MainActor
    private func fetchMessage(id: UUID, context: ModelContext) -> Message? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func loadBody(message: Message) -> String {
        guard let path = message.bodyTextPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

// MARK: - DTOs (Codable mirrors of DraftOutput structs for persistence)

public struct CitationDTO: Codable, Sendable {
    public let claim: String
    public let sourceMessageId: String
    public let sourceLabel: String
}

public struct GapDTO: Codable, Sendable {
    public let description: String
    public let suggestedAction: String
}

public struct DeliverableDTO: Codable, Sendable {
    public let filename: String
    public let filePath: String
    public let sourceMessageId: String
}
