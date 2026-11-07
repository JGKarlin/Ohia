import Foundation
import os
import SwiftData
import OhiaCore

private let draftGenerationLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "draftGenerationTiming"
)

/// Abstraction used by `DraftGenerationOrchestrator` so its persistence
/// and feedback-clearing logic can be unit-tested without constructing a
/// full `DraftOrchestrator` (which pulls in a training engine, vector
/// store, embedder, canonical store, and tool registry).
public protocol DraftGenerating: Sendable {
    @MainActor
    func generateDraft(for message: Message, context: ModelContext) async throws -> DraftOutput
}

/// Optional capability layered on `DraftGenerating`: instruction-driven
/// revision of an existing draft body (the Composer's instruction box).
/// `DraftGenerationOrchestrator` downcasts for it; generators that can't
/// revise (test stubs) simply skip the revision pass.
public protocol DraftRevising: Sendable {
    @MainActor
    func generateRevision(
        for message: Message,
        currentDraft: String,
        instruction: String,
        context: ModelContext
    ) async throws -> DraftRevisionOutput
}

/// Capability for the compose-from-scratch lane: writing (and revising) a
/// brand-new outbound email from the user's brief, keyed off the chosen
/// recipient instead of an incoming message. `DraftGenerationOrchestrator`
/// downcasts for it; generators that can't compose (test stubs) skip the
/// compose pass.
public protocol DraftComposing: Sendable {
    @MainActor
    func generateCompose(for draft: Draft, context: ModelContext) async throws -> DraftOutput

    @MainActor
    func generateComposeRevision(
        for draft: Draft,
        currentDraft: String,
        instruction: String,
        context: ModelContext
    ) async throws -> DraftRevisionOutput
}

/// End-to-end draft generation. Every entry point — initial reply, prepared
/// reply, reply revision, compose, compose revision — freezes one
/// `ComposerGenerationRequest` and runs the same content pipeline: an
/// application-owned brief, one personalized writer call, one publication
/// check and at most one repair, all under one action deadline. The frozen
/// request and brief travel with the output as its generation basis.
public final class DraftOrchestrator: DraftGenerating, DraftRevising, DraftComposing, PreparedReplyGenerating, @unchecked Sendable {

    /// The whole user action — preparation, writing, checking and repair —
    /// shares this budget. Expiry preserves the current body and pending
    /// inputs; the orchestrator permits only bounded retries and never
    /// publishes a late result.
    public static let actionTimeout: TimeInterval = 90

    private let engine: any TrainingEngine
    private let vectorStore: VectorStore
    private let embedder: EmbeddingProvider
    private let canonicalStore: CanonicalStore
    private let hybridRetriever: HybridRetriever?
    private let toolRegistry: ToolRegistry?
    private let contextPackStore: GenerationContextPackStore?
    private let requiresContextPack: Bool
    private let contextPacker: ComposerContextPacker
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private let actions: ComposerGenerationActions

    public init(
        engine: any TrainingEngine,
        vectorStore: VectorStore,
        embedder: EmbeddingProvider,
        canonicalStore: CanonicalStore,
        hybridRetriever: HybridRetriever? = nil,
        toolRegistry: ToolRegistry? = nil,
        contextPackStore: GenerationContextPackStore? = nil,
        requiresContextPack: Bool = false,
        contextPacker: ComposerContextPacker? = nil,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        actions: ComposerGenerationActions = .shared
    ) {
        self.engine = engine
        self.vectorStore = vectorStore
        self.embedder = embedder
        self.canonicalStore = canonicalStore
        self.hybridRetriever = hybridRetriever
        self.toolRegistry = toolRegistry
        self.contextPackStore = contextPackStore
        self.requiresContextPack = requiresContextPack
        self.contextPacker = contextPacker ?? ComposerContextPacker(
            tokenCounter: engine as? any PromptTokenCounting
        )
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
        self.actions = actions
    }

    // MARK: - Reply

    /// Generates a complete draft reply for the given incoming message.
    @MainActor
    public func generateDraft(for message: Message, context: ModelContext) async throws -> DraftOutput {
        let draft = message.draft
        let selected = ComposerSourceCoding.decode(draft?.sourcesJSON)
        let sources = Self.generationSources(for: draft, selected: selected)
        let pack = try packReplyContext(for: message, sources: sources)
        let fit: ComposerWriterWindow.Fit
        if let draft {
            fit = try ComposerGenerationRequestCompiler.writerWindowFit(draft: draft, context: context, pack: pack,
                window: contextPacker.writerWindow)
        } else {
            let state = ComposerInterviewStateCoding.decode(nil) ?? Self.emptyInterviewState()
            fit = try ComposerGenerationRequestCompiler.writerWindowFit(message: message, sources: sources,
                interviewState: state, pack: pack, window: contextPacker.writerWindow, context: context)
        }
        let request = try ComposerGenerationRequestCompiler.request(from: fit)
        let aggregated = try aggregatedContext(for: message, context: context)
        let output = try await generate(request: request, cachedBrief: Self.cachedBrief(for: draft),
            draftID: draft?.id, messageID: message.id, activitySource: "draft")
        return DraftOutput(
            replyText: output.body,
            taskStatuses: aggregated?.taskStatuses ?? [],
            citations: Self.visibleSourceCitations(findings: aggregated?.findings ?? [], sources: pack.sources),
            deliverables: Self.visibleSourceDeliverables(deliverables: aggregated?.deliverables ?? [], sources: pack.sources),
            gaps: aggregated?.gaps ?? [],
            styleExemplarCount: 0,
            appliedRuleNotes: [],
            personalization: Self.capturePersonalization(for: message, context: context, engine: engine,
                generation: output.basis.personalization),
            styleRegisterID: request.presentation.registerID,
            languageID: DraftLanguage.resolvedID(for: message),
            styleControlSnapshot: request.presentation.controls,
            consumedStyleDecisionID: Self.consumedDecisionID(draft: draft, controls: request.presentation.controls),
            generationBasisJSON: try output.basisJSON,
            writerWindowUsage: fit.usage
        )
    }

    @MainActor
    public func generatePreparedReply(
        for message: Message,
        sourcesJSON: String,
        interviewState: ComposerInterviewState,
        context: ModelContext
    ) async throws -> PreparedReplyDraftPayload {
        let sources = ComposerSourceCoding.decode(sourcesJSON)
        let pack = try packReplyContext(for: message, sources: sources)
        let fit = try ComposerGenerationRequestCompiler.writerWindowFit(message: message, sources: sources,
            interviewState: interviewState, pack: pack, window: contextPacker.writerWindow, context: context)
        let request = try ComposerGenerationRequestCompiler.request(from: fit)
        let aggregated = try aggregatedContext(for: message, context: context)
        let output = try await generate(request: request, cachedBrief: nil,
            draftID: nil, messageID: message.id, activitySource: "prepared-reply")
        let draftOutput = DraftOutput(
            replyText: output.body,
            taskStatuses: aggregated?.taskStatuses ?? [],
            citations: Self.visibleSourceCitations(findings: aggregated?.findings ?? [], sources: pack.sources),
            deliverables: Self.visibleSourceDeliverables(deliverables: aggregated?.deliverables ?? [], sources: pack.sources),
            gaps: aggregated?.gaps ?? [],
            appliedRuleNotes: [],
            personalization: Self.capturePersonalization(for: message, context: context, engine: engine,
                generation: output.basis.personalization),
            styleRegisterID: request.presentation.registerID,
            languageID: DraftLanguage.resolvedID(for: message),
            styleControlSnapshot: request.presentation.controls,
            generationBasisJSON: try output.basisJSON,
            writerWindowUsage: fit.usage
        )
        return PreparedReplyDraftPayload(
            output: draftOutput,
            generatedAt: .now,
            sourceThreadCount: message.thread?.messages.count ?? 1
        )
    }

    @MainActor
    public func preparedReplyWriterWindowUsage(
        for message: Message,
        sourcesJSON: String,
        interviewState: ComposerInterviewState,
        context: ModelContext
    ) throws -> ComposerWriterWindowUsage {
        let sources = ComposerSourceCoding.decode(sourcesJSON)
        let pack = try packReplyContext(for: message, sources: sources)
        return try ComposerGenerationRequestCompiler.writerWindowFit(message: message, sources: sources,
            interviewState: interviewState, pack: pack, window: contextPacker.writerWindow,
            context: context).usage
    }

    /// Instruction-driven or presentation-only revision of a reply draft. A
    /// presentation-only change reuses the displayed revision's validated
    /// brief; a content change prepares a new one.
    @MainActor
    public func generateRevision(
        for message: Message,
        currentDraft: String,
        instruction: String,
        context: ModelContext
    ) async throws -> DraftRevisionOutput {
        guard let draft = message.draft else {
            throw TrainingEngineError.generationFailed("The message has no draft to revise.")
        }
        let sources = Self.generationSources(for: draft, selected: ComposerSourceCoding.decode(draft.sourcesJSON))
        let pack = try packReplyContext(for: message, sources: sources)
        let fit = try ComposerGenerationRequestCompiler.writerWindowFit(draft: draft, context: context, pack: pack,
            window: contextPacker.writerWindow, currentBody: currentDraft, instruction: instruction)
        let request = try ComposerGenerationRequestCompiler.request(from: fit)
        let output = try await generate(request: request, cachedBrief: Self.cachedBrief(for: draft),
            draftID: draft.id, messageID: message.id, activitySource: "draft-revision")
        return DraftRevisionOutput(replyText: output.body, generationBasisJSON: try output.basisJSON,
            writerWindowUsage: fit.usage)
    }

    // MARK: - Compose

    @MainActor
    public func generateCompose(for draft: Draft, context: ModelContext) async throws -> DraftOutput {
        guard let recipient = Self.composeRecipient(for: draft) else {
            throw TrainingEngineError.generationFailed("Compose draft has no recipient to write to.")
        }
        let brief = draft.composeInstruction ?? ""
        guard brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TrainingEngineError.generationFailed("Compose draft has no brief to write from.")
        }
        let sources = Self.generationSources(for: draft, selected: ComposerSourceCoding.decode(draft.sourcesJSON))
        let pack = try packComposeContext(brief: brief, subject: draft.composeSubject ?? "", recipient: recipient, sources: sources)
        let fit = try ComposerGenerationRequestCompiler.writerWindowFit(draft: draft, context: context, pack: pack,
            window: contextPacker.writerWindow)
        let request = try ComposerGenerationRequestCompiler.request(from: fit)
        let output = try await generate(request: request, cachedBrief: Self.cachedBrief(for: draft),
            draftID: draft.id, messageID: nil, activitySource: "compose")
        return DraftOutput(
            replyText: output.body,
            taskStatuses: [],
            citations: [],
            deliverables: [],
            gaps: [],
            personalization: Self.capturePersonalizationForCompose(recipientAddress: recipient, context: context, engine: engine,
                generation: output.basis.personalization),
            styleRegisterID: request.presentation.registerID,
            languageID: request.content.languageID == "und" ? nil : request.content.languageID,
            styleControlSnapshot: request.presentation.controls,
            consumedStyleDecisionID: Self.consumedDecisionID(draft: draft, controls: request.presentation.controls),
            generationBasisJSON: try output.basisJSON,
            writerWindowUsage: fit.usage
        )
    }

    @MainActor
    public func generateComposeRevision(
        for draft: Draft,
        currentDraft: String,
        instruction: String,
        context: ModelContext
    ) async throws -> DraftRevisionOutput {
        guard let recipient = Self.composeRecipient(for: draft) else {
            throw TrainingEngineError.generationFailed("Compose draft has no recipient to write to.")
        }
        let sources = Self.generationSources(for: draft, selected: ComposerSourceCoding.decode(draft.sourcesJSON))
        let pack = try packComposeContext(brief: draft.composeInstruction ?? "", subject: draft.composeSubject ?? "",
            recipient: recipient, sources: sources)
        let fit = try ComposerGenerationRequestCompiler.writerWindowFit(draft: draft, context: context, pack: pack,
            window: contextPacker.writerWindow, currentBody: currentDraft, instruction: instruction)
        let request = try ComposerGenerationRequestCompiler.request(from: fit)
        let output = try await generate(request: request, cachedBrief: Self.cachedBrief(for: draft),
            draftID: draft.id, messageID: nil, activitySource: "compose-revision")
        return DraftRevisionOutput(replyText: output.body, generationBasisJSON: try output.basisJSON,
            writerWindowUsage: fit.usage)
    }

    // MARK: - The one pipeline

    private struct Generated {
        let body: String
        let basis: ComposerGenerationBasis
        var basisJSON: String { get throws { try basis.json } }
    }

    /// The drafting executor: the draft check's answer carries its JSON comma limit.
    nonisolated static func executor(engine: any TrainingEngine, action: ComposerGenerationAction,
                                     activityPublisher: ModelActivityStatusPublisher?,
                                     activitySource: String) -> ComposerModelExecutor {
        ComposerModelExecutor(engine: engine, action: action,
            auditorCommaLimit: ComposerPublicationAudit.answerCommaLimit,
            activityPublisher: activityPublisher, activitySource: activitySource)
    }

    /// Runs the content pipeline for one frozen request under one action
    /// deadline. Content-contract failures are terminal for the orchestrator's
    /// retry policy: repeating the same request cannot repair them, and the
    /// user's body and pending inputs stay untouched.
    @MainActor
    private func generate(
        request: ComposerGenerationRequest,
        cachedBrief: ComposerContentBrief?,
        draftID: UUID?,
        messageID: UUID?,
        activitySource: String
    ) async throws -> Generated {
        let action = ComposerGenerationAction(timeout: Self.actionTimeout)
        actions.register(action, draftID: draftID, messageID: messageID)
        defer { actions.unregister(action) }
        let executor = Self.executor(engine: engine, action: action,
            activityPublisher: modelActivityStatusPublisher, activitySource: activitySource)
        let started = Date()
        draftGenerationLogger.notice("start request=\(request.requestID.uuidString, privacy: .public) phase=\(activitySource, privacy: .public) cachedBrief=\(cachedBrief != nil)")
        do {
            let output = try await ComposerContentPipeline.generate(request: request, cachedBrief: cachedBrief, action: action) {
                prompt, role, limit in try await executor.call(prompt, role, limit)
            }
            let stages = output.stages.map { stage in
                let timing = stage.timingSummary
                return "\(stage.role.rawValue)=\(String(format: "%.1f", stage.elapsed))s" + (timing.isEmpty ? "" : "(\(timing))")
            }.joined(separator: " ")
            let findings = output.check.findings.map(\.kind.rawValue).joined(separator: ",")
            draftGenerationLogger.notice("end request=\(request.requestID.uuidString, privacy: .public) phase=\(activitySource, privacy: .public) elapsedSeconds=\(Date().timeIntervalSince(started)) calls=\(output.modelCallCount) stages=\(stages, privacy: .public) check=\(output.check.outcome.rawValue, privacy: .public) findings=\(findings, privacy: .public) detail=\(output.check.detail ?? "", privacy: .public)")
            return Generated(body: output.body, basis: ComposerGenerationBasis(request: request, brief: output.brief,
                writerTask: ComposerWriterPrompt.taskIdentifier, personalization: output.personalization,
                diagnostics: output.diagnostics, check: output.check))
        } catch let error as ComposerContentError {
            // Findings quote the draft, so only the failure kind is release-visible.
            draftGenerationLogger.notice("failed request=\(request.requestID.uuidString, privacy: .public) phase=\(activitySource, privacy: .public) elapsedSeconds=\(Date().timeIntervalSince(started)) kind=\(error.kind, privacy: .public)")
            if error == .deadlineExceeded { throw error }
            throw DraftContentValidationError.rejected(error.errorDescription ?? error.kind)
        }
    }

    /// The brief of the generated revision the live body derives from, reused
    /// when the new request has the same content identity (the pipeline
    /// verifies that itself).
    @MainActor
    static func cachedBrief(for draft: Draft?) -> ComposerContentBrief? {
        guard let generated = draft?.baseGeneratedRevision else { return nil }
        return ComposerGenerationBasis.decode(generated.generationBasisJSON)?.brief
    }

    private static func consumedDecisionID(draft: Draft?, controls: StyleControlSnapshot?) -> UUID? {
        draft?.pendingStyleControlSnapshot.flatMap { $0.decisionID == controls?.decisionID ? $0.decisionID : nil }
    }

    /// The prepared context pack supplies citation, deliverable and gap
    /// metadata for the Composer's panes. It is never writer input.
    @MainActor
    private func aggregatedContext(for message: Message, context: ModelContext) throws -> AggregatedContext? {
        if let pack = try contextPackStore?.pack(for: message.id) {
            return pack.context
        }
        guard !requiresContextPack else {
            throw GenerationContextPackError.missing(message.id)
        }
        return try DraftContextPackBuilder.build(
            for: message,
            context: context,
            vectorStore: vectorStore,
            embedder: embedder,
            canonicalStore: canonicalStore,
            hybridRetriever: hybridRetriever,
            toolRegistry: toolRegistry
        )
    }

    // MARK: - Metadata helpers

    static func visibleSourceCitations(
        findings: [Finding],
        sources: [ComposerSource]
    ) -> [Citation] {
        let visibleMessageIDs = Set(
            sources.compactMap(\.messageID).map { $0.uuidString.lowercased() }
        )
        return findings.compactMap { finding -> Citation? in
            guard let sourceID = finding.sourceMessageId,
                  visibleMessageIDs.contains(sourceID.lowercased()) else {
                return nil
            }
            return Citation(
                claim: finding.text,
                sourceMessageId: sourceID,
                confidence: finding.confidence
            )
        }
    }

    static func visibleSourceDeliverables(
        deliverables: [Deliverable],
        sources: [ComposerSource]
    ) -> [Deliverable] {
        let visibleMessageIDs = Set(
            sources.compactMap(\.messageID).map { $0.uuidString.lowercased() }
        )
        return deliverables.filter {
            visibleMessageIDs.contains($0.sourceMessageId.lowercased())
        }
    }

    /// The register for an explicit user choice, when it still exists, is
    /// active, and covers the draft's language — styles are language-scoped,
    /// so a stamped choice never survives a language switch it can't serve.
    /// Nil falls resolution through to the shared (language-filtered) chain.
    @MainActor
    static func explicitRegister(
        id: UUID?,
        language: String?,
        context: ModelContext
    ) -> StyleRegister? {
        guard let id,
              let register = StyleRegisterResolver.register(
                withID: id,
                language: language,
                context: context
              ) else {
            return nil
        }
        return register
    }

    static func styleControlSnapshot(
        for draft: Draft?,
        register: StyleRegisterNote?,
        includingPending: Bool
    ) -> StyleControlSnapshot? {
        if includingPending,
           let pending = draft?.pendingStyleControlSnapshot,
           pending.registerID == register?.id {
            return pending
        }
        if let applied = draft?.styleControlSnapshot,
           applied.registerID == register?.id {
            return applied
        }
        guard let register else { return nil }
        return .inherited(
            registerID: register.id,
            registerRevision: register.revision,
            defaults: register.axes
        )
    }

    /// Reads promoted adapter / corpus authority at generation time. Optimizer
    /// steps that have not crossed the persisted promotion boundary must never
    /// appear in a generated draft's personalization provenance.
    @MainActor
    static func capturePersonalization(
        for message: Message,
        context: ModelContext,
        engine: (any TrainingEngine)? = nil,
        generation: GenerationPersonalization? = nil
    ) -> PersonalizationSnapshot {
        let adapterActive = generation?.adapterActive ?? engine?.isAdapterLoaded ?? false
        let lineage = adapterActive ? capturedVoiceLineage(context: context, engine: engine, generation: generation) : nil
        let adapterStep = lineage?.checkpoint.stepCount ?? 0
        let trainedPairs = trainedPairCount(context: context, lineage: lineage)
        let correspondentReplies = ComposerSourceCompiler.correspondentReplyCount(
            for: message,
            context: context
        )

        return PersonalizationSnapshot(
            adapterActive: adapterActive,
            adapterStep: adapterStep,
            totalPairsTrained: trainedPairs,
            correspondentReplyCount: correspondentReplies
        )
    }

    /// Compose analogue of `capturePersonalization` — same adapter/corpus
    /// basis, with the per-correspondent reply count keyed off the recipient.
    @MainActor
    static func capturePersonalizationForCompose(
        recipientAddress: String,
        context: ModelContext,
        engine: (any TrainingEngine)? = nil,
        generation: GenerationPersonalization? = nil
    ) -> PersonalizationSnapshot {
        let adapterActive = generation?.adapterActive ?? engine?.isAdapterLoaded ?? false
        let lineage = adapterActive ? capturedVoiceLineage(context: context, engine: engine, generation: generation) : nil
        let adapterStep = lineage?.checkpoint.stepCount ?? 0
        let trainedPairs = trainedPairCount(context: context, lineage: lineage)
        let recipientReplies = ComposeSourceCompiler.recipientReplyCount(
            recipientAddress: recipientAddress,
            context: context
        )
        return PersonalizationSnapshot(
            adapterActive: adapterActive,
            adapterStep: adapterStep,
            totalPairsTrained: trainedPairs,
            correspondentReplyCount: recipientReplies
        )
    }

    /// Generation metadata identifies the actual loaded artifact, including
    /// fallback to an older checkpoint. Unknown artifacts claim no history.
    @MainActor
    private static func capturedVoiceLineage(context: ModelContext, engine: (any TrainingEngine)?,
                                             generation: GenerationPersonalization?) -> CheckpointManager.VoiceLineage? {
        if let generation {
            guard generation.adapterActive, generation.adapterRevision != nil else { return nil }
            return try? CheckpointManager.voiceLineage(compatibility: nil,
                modelID: generation.modelID, adapterRevision: generation.adapterRevision, context: context)
        }
        return try? CheckpointManager.voiceLineage(
            compatibility: (engine as? any CheckpointAwareTrainingEngine)?.checkpointCompatibility, context: context)
    }

    /// Count of current pair revisions incorporated by promoted checkpoints,
    /// read only while an adapter is actually loaded: generation on base
    /// weights (a fresh install, or a task change that orphaned the old
    /// adapter) was trained on nothing, whatever an earlier task stamped.
    @MainActor
    private static func trainedPairCount(context: ModelContext, lineage: CheckpointManager.VoiceLineage?) -> Int {
        guard let lineage else { return 0 }
        return (try? TrainingCorpusPlanner.incorporatedPairs(context: context, learnedRevisions: lineage.revisions).count) ?? 0
    }

    /// The incoming message text every reply measurement and generation
    /// packs, so the writer fit Composer shows is the one the writer uses.
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
        brief: String,
        subject: String,
        recipient: String,
        sources: [ComposerSource]
    ) throws -> ComposerContextPack {
        try QuestionGroundingContextPacking.compose(
            brief: brief,
            subject: subject,
            recipient: recipient,
            sources: sources,
            packer: contextPacker
        )
    }

    static func currentResolvedGroundings(
        state: ComposerInterviewState,
        contextPack: ComposerContextPack,
        framing: ComposerInterviewFraming,
        accountID: UUID?,
        subject: String,
        languageIdentifier: String
    ) -> [QuestionGrounding] {
        QuestionGroundingResolver.currentGroundings(
            state.groundings,
            questions: state.baseProtocol.questionNodes,
            contextPack: contextPack,
            framing: framing,
            subject: subject,
            accountID: accountID,
            languageIdentifier: languageIdentifier
        )
        .filter { QuestionGroundingValidation.isResolvedFact($0) }
    }

    private static func emptyInterviewState() -> ComposerInterviewState {
        ComposerInterviewState(
            contractVersion: ComposerInterviewPlanner.contractVersion,
            inputFingerprint: "",
            evidenceFingerprint: "",
            generationEpoch: 0,
            planningOutcome: .empty,
            baseProtocol: ComposerInterviewPlanner.emptyProtocol
        )
    }

    @MainActor
    static func generationSources(
        for draft: Draft?,
        selected: [ComposerSource]
    ) -> [ComposerSource] {
        guard let overlay = ComposerDecisionResearchOverlayCoding.decode(
            draft?.decisionResearchOverlayJSON
        ), overlay.outcome == .populated else {
            return selected
        }
        let selectedIDs = Set(selected.map(\.id))
        return selected + overlay.sources.filter { !selectedIDs.contains($0.id) }
    }

    /// First recipient address (lowercased) of a compose draft, or nil when
    /// the To list is empty.
    private static func composeRecipient(for draft: Draft) -> String? {
        let first = ComposeAddressEncoding.decode(draft.composeToJSON)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let first, !first.isEmpty else { return nil }
        return first
    }
}
