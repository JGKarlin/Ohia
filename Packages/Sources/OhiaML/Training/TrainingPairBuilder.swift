import Foundation
import SwiftData
import OhiaCore

/// Builds and rebuilds training pairs for the Composer writer task. Every
/// pair's prompt is the runtime writer input rendered from a frozen request
/// and brief; its completion is the text the author actually sent. One
/// function projects every kind of evidence, so an accepted Composer send, a
/// send made before bases were recorded and a historical sent reply all train
/// the same task.
public final class TrainingPairBuilder: @unchecked Sendable {
    /// Signal source of a pair built from an accepted Composer send.
    public static let acceptedSendSignalSource = "writer_send"
    /// Signal source kept for pairs built before the writer task from an
    /// endorsed instruction revision; rebuilt pairs carry `acceptedSendSignalSource`.
    public static let instructionRevisionSignalSource = "instruction_revision"
    /// Model-needing rows per preparation job, so one job stays a few
    /// minutes long and admission re-evaluates between jobs.
    public static let reconstructionsPerJob = 8

    private let canonicalStore: CanonicalStore

    public init(canonicalStore: CanonicalStore) {
        self.canonicalStore = canonicalStore
    }

    // MARK: - Endorsement

    /// The instruction revision the user endorsed by sending: the last typed
    /// instruction or instructed restyle, unless a later regenerate rejected
    /// its lineage. Initial and regenerate revisions may carry first-draft
    /// guidance in `instruction`, but they are fresh passes that did not
    /// rewrite a predecessor, and pairing them would map the guidance onto a
    /// version it never touched.
    @MainActor
    public static func endorsedInstructionRevision(of draft: Draft) -> DraftRevision? {
        let ordered = draft.orderedRevisions
        guard let candidate = ordered.last(where: { revision in
            (revision.triggerRaw == DraftRevisionTrigger.instruction
                || revision.triggerRaw == DraftRevisionTrigger.restyle)
                && revision.instruction?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
        }) else { return nil }
        let regeneratedAfter = ordered.contains { revision in
            revision.index > candidate.index
                && revision.triggerRaw == DraftRevisionTrigger.regenerate
        }
        return regeneratedAfter ? nil : candidate
    }

    // MARK: - Projection

    /// What projecting one evidence row produced.
    public enum Projection: Sendable {
        case example(ComposerWriterTraining.Example)
        /// The evidence needs one base-model call and no engine was supplied.
        case needsModel
        /// Foreground demand or task cancellation interrupted this job. No
        /// evidence outcome is recorded; the same row can resume next job.
        case interrupted
        case excluded(SentTrainingEvidenceReason)
        case failed(SentTrainingEvidenceReason, retryable: Bool)
    }

    /// Shared per-job state: the packer, the model call, the per-job budget
    /// of reconstructions, and a message index built only when a row needs
    /// the model, so a job that can do nothing never reads the message table.
    @MainActor
    public final class Session {
        let packer: ComposerContextPacker
        let engine: (any TrainingEngine)?
        var reconstructionsRemaining = TrainingPairBuilder.reconstructionsPerJob
        private var cachedIndex: ComposerWriterTraining.MessageIndex?
        private let shouldYield: @MainActor @Sendable () -> Bool
        private var yielded = false

        public init(engine: (any TrainingEngine)?,
                    shouldYield: @escaping @MainActor @Sendable () -> Bool = { false }) {
            self.packer = ComposerContextPacker(tokenCounter: engine as? any PromptTokenCounting)
            self.engine = engine?.isModelLoaded == true ? engine : nil
            self.shouldYield = shouldYield
        }

        /// The writer window measured with the session's tokenizer.
        var window: ComposerWriterWindow { packer.writerWindow }

        /// Whether a stored or rendered example fits the trained window; nil
        /// without a loaded tokenizer, when nothing may be decided from a
        /// stand-in count.
        func fitsTrainingWindow(prompt: String, completion: String) -> Bool? {
            try? ComposerWriterTraining.fitsTrainingWindow(prompt: prompt, completion: completion, window: window)
        }

        func needsToYield() -> Bool {
            if yielded { return true }
            if Task.isCancelled || shouldYield() { yielded = true }
            return yielded
        }

        func index(context: ModelContext) throws -> ComposerWriterTraining.MessageIndex {
            if let cachedIndex { return cachedIndex }
            let index = try ComposerWriterTraining.MessageIndex(context: context)
            cachedIndex = index
            return index
        }

        var hasBuiltIndex: Bool { cachedIndex != nil }

        /// The message a sent reply answered, for reading its body. A job
        /// that can call the model reads the same parent its prompt will
        /// (the mailbox index); one that cannot looks only in the reply's own
        /// thread, never reading the whole message table.
        func repliedTo(_ sent: Message, context: ModelContext) -> Message? {
            let tokens = normalizedMessageIDTokens(sent.inReplyTo).sorted()
            guard !tokens.isEmpty else { return nil }
            if engine != nil, let index = try? index(context: context) { return index.incoming(for: sent) }
            let accountID = sent.accountID ?? sent.account?.id
            let members = (sent.thread?.messages ?? []).filter { member in
                member.id != sent.id && !member.isTrashed
                    && (accountID == nil || (member.accountID ?? member.account?.id) == accountID)
            }
            for token in tokens {
                if let member = members.first(where: { normalizedMessageIDTokens($0.messageIdHeader).contains(token) }) {
                    return member
                }
            }
            return nil
        }

        /// A model call that reserves the row's reconstruction slot on its first
        /// use, so a row rejected before any model call (a window or text
        /// check) spends none. Later calls for the row reuse the slot.
        func lazyReconstruction() -> ComposerModelCall {
            let slot = ReconstructionSlot(session: self)
            return { prompt, role, limit in try await slot.call(prompt, role, limit) }
        }

        /// Reserve one row from the job budget. Reconstruction and semantic
        /// verification run in the background and yield to foreground demand.
        func takeReconstruction() -> ComposerModelCall? {
            guard let engine, reconstructionsRemaining > 0 else { return nil }
            reconstructionsRemaining -= 1
            return { prompt, role, limit in
                try await self.reconstruct(prompt, role, limit, engine: engine)
            }
        }

        private func reconstruct(_ prompt: PrefixCachedPrompt, _ role: ComposerModelRole, _ limit: Int,
                                 engine: any TrainingEngine) async throws -> ComposerModelOutput {
            guard !needsToYield() else { throw CancellationError() }
            let action = ComposerGenerationAction(timeout: 360)
            // A started reconstruction can occupy the model for minutes.
            // Monitor admission while it runs, cancelling only this action's
            // token so a queued foreground request is never cancelled with it.
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    if self.needsToYield() {
                        action.cancel()
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
            }
            defer { monitor.cancel() }
            var verificationSampling = GenerationSampling.deterministic
            verificationSampling.seed = 42
            let executor = ComposerModelExecutor(engine: engine, action: action, forceBase: true,
                sampling: verificationSampling)
            return try await executor.call(prompt, role, limit,
                thinkingTokens: role == .auditor ? ComposerWriterTraining.verificationThinkingTokens : nil)
        }
    }

    @MainActor
    final class ReconstructionSlot {
        private let session: Session
        private var reserved: ComposerModelCall?

        init(session: Session) { self.session = session }

        func call(_ prompt: PrefixCachedPrompt, _ role: ComposerModelRole, _ limit: Int) async throws -> ComposerModelOutput {
            if reserved == nil {
                // The job's budget ran out before this row needed the model:
                // the row resumes in a later job.
                guard let call = session.takeReconstruction() else { throw CancellationError() }
                reserved = call
            }
            guard let reserved else { throw CancellationError() }
            return try await reserved(prompt, role, limit)
        }
    }

    /// The writer-task example for one evidence row, by provenance:
    /// - an accepted Composer send retains its frozen sources and reconstructs final decisions;
    /// - a send without a basis compiles from its draft's recorded decisions;
    /// - historical mail reconstructs neutral units from the sent text.
    /// Unchanged verified projections reuse their content and measured style.
    @MainActor
    public func project(_ evidence: SentTrainingEvidence, session: Session, context: ModelContext) async -> Projection {
        let outcome = await unscoredProject(evidence, session: session, context: context)
        guard case .example(var example) = outcome else { return outcome }
        let text = TrainingPromptFormatter.storedCompletionBody(example.completion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = DraftLanguage.detectedFamilyID(ofText: text) ?? example.provenance.languageID
        do {
            // Accepted sends keep their immutable source snapshot, but their
            // verified final content need only be reconstructed once per revision.
            if example.basis.trainingReconstructionVersion != ComposerWriterTraining.reconstructionVersion {
                for pair in evidence.trainingPairs where pair.evidenceRevision == evidence.revision {
                    guard TrainingPromptFormatter.storedCompletionBody(pair.completionText)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == text,
                        let basis = ComposerGenerationBasis.decode(pair.generationBasisJSON),
                        basis.trainingReconstructionVersion == ComposerWriterTraining.reconstructionVersion,
                        (try? basis.brief.validate(against: basis.request.content)) != nil else { continue }
                    example.basis = basis
                    example.provenance.contentIdentity = basis.brief.contentIdentity
                    example.provenance.reconstructionVersion = ComposerWriterTraining.reconstructionVersion
                    example.measuredStyleScore = SentMessageStyleScore.decode(pair.measuredStyleScoreJSON)
                    break
                }
            }
            if example.basis.trainingReconstructionVersion != ComposerWriterTraining.reconstructionVersion {
                // A send rejected by the window check before any model call
                // spends no reconstruction.
                guard session.engine != nil, session.reconstructionsRemaining > 0 else { return .needsModel }
                example = try await ComposerWriterTraining.reconstructAcceptedCompletion(example,
                    window: session.window, generate: session.lazyReconstruction())
            }
            if example.basis.request.content.languageID != language {
                example.basis.request.content.languageID = language
                example.basis.brief = try ComposerContentBrief.prepared(from: example.basis.request.content)
                example.provenance.languageID = language
                example.provenance.contentIdentity = example.basis.brief.contentIdentity
            }
            let score: SentMessageStyleScore
            if let cached = example.measuredStyleScore ?? SentMessageStyleScore.decode(evidence.measuredStyleScoreJSON),
               cached.matches(text: text, languageID: language) {
                score = cached
            } else {
                guard let generate = session.takeReconstruction() else { return .needsModel }
                score = try await SentMessageStyleScorer.measure(text: text, languageID: language, generate: generate)
            }
            example.requestedStyleControls = evidence.sourceOutbox?.styleControlSnapshot
                ?? (evidence.sourceOutbox == nil ? nil : example.basis.request.presentation.controls)
            example.measuredStyleScore = score
            example.basis = try ComposerWriterTraining.condition(example.basis, on: score)
            example.prompt = try ComposerWriterPrompt.render(request: example.basis.request,
                brief: example.basis.brief, authorSentenceEdits: 0).prompt
            // A reused basis built before the writer window may not fit; it
            // is rejected only on a real tokenizer count.
            if session.fitsTrainingWindow(prompt: example.prompt, completion: example.completion) == false {
                throw ComposerWriterTraining.Ineligibility.exceedsTrainingWindow
            }
            return .example(example)
        } catch let error as ComposerWriterTraining.Ineligibility {
            return Self.projection(for: error)
        } catch is CancellationError {
            return .interrupted
        } catch TrainingEngineError.modelNotLoaded {
            return .needsModel
        } catch {
            return .failed(.unsupportedEvidenceShape, retryable: true)
        }
    }

    @MainActor
    private func unscoredProject(_ evidence: SentTrainingEvidence, session: Session, context: ModelContext) async -> Projection {
        guard evidence.learningPreference != .explicitDisabled,
              evidence.learningPreference != .automaticDisabled else { return .excluded(.userOptOut) }
        if let item = evidence.sourceOutbox, item.status == .sent {
            guard item.learnFromSend else { return .excluded(.userOptOut) }
            guard !AuthoredReplyText.extract(from: item.plainBody).isEmpty else { return .excluded(.missingBody) }
            if let thread = item.message?.thread?.messages,
               ComposerWriterTraining.isResend(AuthoredReplyText.extract(from: item.plainBody),
                   earlierSends: ComposerWriterTraining.earlierAuthoredTexts(in: thread, before: item.createdAt,
                       excluding: evidence.sourceMessage?.id, messageID: item.messageIDHeader)) {
                return .excluded(.resendOfEarlierSend)
            }
            if let draft = item.draft {
                let finalText = AuthoredReplyText.extract(from: item.plainBody)
                let unchanged = draft.orderedRevisions.contains {
                    $0.triggerRaw != DraftRevisionTrigger.manualEdit
                        && AuthoredReplyText.extract(from: $0.bodyText) == finalText
                }
                guard !unchanged || Self.endorsedInstructionRevision(of: draft) != nil else {
                    return .excluded(.unchangedGeneratedOutput)
                }
            }
            do {
                if item.generationBasisJSON != nil {
                    do {
                        return .example(try ComposerWriterTraining.example(fromSend: item))
                    } catch let error as ComposerContentError {
                        // A frozen basis this build cannot render (a contract
                        // version it cannot complete) is not the end of the
                        // evidence: the draft's own decisions, or the sent
                        // mail, still describe the email.
                        print("[Ohia] training send basis skipped: \(error.kind)")
                    }
                }
                if item.draft != nil {
                    do {
                        guard session.engine != nil, session.reconstructionsRemaining > 0 else { return .needsModel }
                        return .example(try await ComposerWriterTraining.example(fromDraftSend: item,
                            packer: session.packer, context: context) { prompt, role, limit in
                                // Compile first: a draft with no instructions
                                // falls through without spending two row slots.
                                guard let generate = await session.takeReconstruction() else { throw CancellationError() }
                                return try await generate(prompt, role, limit)
                            })
                    } catch ComposerWriterTraining.Ineligibility.noGenerationBasis {
                        // No recorded instruction: reconstruct from the sent mail below.
                    } catch let error as ComposerContentError {
                        // A draft whose recorded decisions no longer compile
                        // (an older draft without ordering history) is
                        // reconstructed from the sent mail instead.
                        print("[Ohia] training send draft compile skipped: \(error.kind)")
                    }
                }
            } catch is CancellationError {
                return .interrupted
            } catch let error as ComposerWriterTraining.Ineligibility {
                return Self.projection(for: error)
            } catch TrainingEngineError.modelNotLoaded {
                // The writer fit counts only with the loaded tokenizer.
                return .needsModel
            } catch {
                print("[Ohia] training send projection failed: \(String(reflecting: type(of: error)))")
                return .failed(.unsupportedEvidenceShape, retryable: true)
            }
            // The sent message must have synced back before its text can be
            // reconstructed; until then the row waits and is retried.
            guard let sent = evidence.sourceMessage else { return .failed(.missingBody, retryable: true) }
            return await reconstruct(sent: sent, evidence: evidence, session: session, context: context)
        }
        guard let sent = evidence.sourceMessage else { return .failed(.unsupportedEvidenceShape, retryable: false) }
        return await reconstruct(sent: sent, evidence: evidence, session: session, context: context)
    }

    @MainActor
    private func reconstruct(sent: Message, evidence: SentTrainingEvidence, session: Session, context: ModelContext) async -> Projection {
        guard !sent.isTrashed else { return .excluded(.trashedSource) }
        guard sent.isSentByUser, !isOhiaComposerMailboxDraftMessageID(sent.messageIdHeader) else {
            return .failed(.unsupportedEvidenceShape, retryable: false)
        }
        guard sent.isAutomatedOrBulk != true else { return .excluded(.automatedResponse) }
        guard let bodyPath = sent.bodyTextPath, FileManager.default.fileExists(atPath: bodyPath),
              let raw = try? String(contentsOfFile: bodyPath, encoding: .utf8) else {
            return .failed(.missingBody, retryable: true)
        }
        let authored = ComposerWriterTraining.authoredText(ofSent: raw) {
            session.repliedTo(sent, context: context)
        }
        guard !authored.isEmpty else { return .excluded(.missingBody) }
        guard TrivialReplyFilter.classify(authored) != .exclude else { return .excluded(.trivialAcknowledgment) }
        let earlierSends = ComposerWriterTraining.earlierAuthoredTexts(in: sent.thread?.messages ?? [],
            before: sent.sentAt ?? sent.receivedAt ?? .distantFuture, excluding: sent.id, messageID: sent.messageIdHeader)
        if ComposerWriterTraining.isResend(authored, earlierSends: earlierSends) { return .excluded(.resendOfEarlierSend) }
        let isStandalone = sent.inReplyTo?.isEmpty != false
        if !isStandalone && normalizedMessageIDTokens(sent.inReplyTo).isEmpty { return .failed(.malformedThreading, retryable: false) }
        // A prompt-template change does not invalidate already verified
        // authored content. Re-render its frozen request with the same exact-
        // text measurement instead of reconstructing and scoring it again.
        // Changed text/revision, missing scores or invalid bases take the
        // ordinary preparation path below.
        for pair in evidence.trainingPairs where pair.evidenceRevision == evidence.revision {
            guard TrainingPromptFormatter.storedCompletionBody(pair.completionText)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == authored,
                  var basis = ComposerGenerationBasis.decode(pair.generationBasisJSON),
                  basis.trainingReconstructionVersion == ComposerWriterTraining.reconstructionVersion,
                  let score = SentMessageStyleScore.decode(pair.measuredStyleScoreJSON),
                  score.matches(text: authored, languageID: basis.request.content.languageID),
                  (try? basis.brief.validate(against: basis.request.content)) != nil else { continue }
            do {
                basis = try ComposerWriterTraining.condition(basis, on: score)
                basis.brief = try ComposerContentBrief.prepared(from: basis.request.content)
                let prompt = try ComposerWriterPrompt.render(request: basis.request, brief: basis.brief,
                    authorSentenceEdits: 0).prompt
                // A basis built before the writer window that overflows it is
                // rebuilt below, where the fit applies.
                guard session.fitsTrainingWindow(prompt: prompt, completion: pair.completionText) != false else { continue }
                return .example(ComposerWriterTraining.Example(
                    prompt: prompt,
                    completion: pair.completionText,
                    provenance: .init(source: .historicalReconstruction, messageID: sent.id,
                        outboxItemID: nil, pairID: pair.id, role: pair.trainingRoleRaw,
                        languageID: basis.request.content.languageID,
                        authoredTextDigest: ComposerContentCoding.digest(Data(authored.utf8)),
                        evidenceDigests: basis.request.content.allEvidence.map(\.contentDigest),
                        contentIdentity: basis.brief.contentIdentity, writerTask: ComposerWriterPrompt.taskIdentifier,
                        reconstructionVersion: nil, reconstructedUnits: nil, manualEditCount: 0),
                    basis: basis, measuredStyleScore: score, requestedStyleControls: pair.styleControlSnapshot))
            } catch {
                continue
            }
        }
        guard session.engine != nil, session.reconstructionsRemaining > 0 else { return .needsModel }
        if isStandalone {
            let reconstruct = session.lazyReconstruction()
            do {
                let pack = try session.packer.pack(anchorText: "", anchorTerms: [], sources: [])
                return .example(try await ComposerWriterTraining.reconstruct(sent: sent, incoming: nil,
                    pack: pack, window: session.window, context: context, generate: reconstruct))
            } catch is CancellationError { return .interrupted }
            catch let error as ComposerWriterTraining.Ineligibility { return Self.projection(for: error) }
            catch TrainingEngineError.modelNotLoaded { return .needsModel }
            catch { return .failed(.unsupportedEvidenceShape, retryable: true) }
        }
        guard let index = try? session.index(context: context),
              let correspondence = ComposerWriterTraining.correspondence(for: sent, index: index),
              let incomingPath = correspondence.incoming.bodyTextPath,
              FileManager.default.fileExists(atPath: incomingPath) else {
            return .failed(.missingParent, retryable: true)
        }
        let reconstruct = session.lazyReconstruction()
        do {
            let pack = try QuestionGroundingContextPacking.reply(message: correspondence.incoming,
                bodyText: QuestionGroundingContextPacking.replyAnchorText(for: correspondence.incoming),
                sources: correspondence.sources, packer: session.packer)
            let example = try await ComposerWriterTraining.reconstruct(sent: sent, incoming: correspondence.incoming,
                pack: pack, window: session.window, context: context, generate: reconstruct)
            return .example(example)
        } catch is CancellationError {
            return .interrupted
        } catch let error as ComposerWriterTraining.Ineligibility {
            return Self.projection(for: error)
        } catch TrainingEngineError.modelNotLoaded {
            // The fit counts only with the loaded tokenizer; the row waits.
            return .needsModel
        } catch is ComposerContentError {
            // A model protocol/plan failure says nothing about the validity of
            // the correspondence. Preserve existing pairs and retry later.
            return .failed(.unsupportedEvidenceShape, retryable: true)
        } catch {
            return .failed(.unsupportedEvidenceShape, retryable: true)
        }
    }

    private static func projection(for error: ComposerWriterTraining.Ineligibility) -> Projection {
        switch error {
        case .notAcceptedSend: .excluded(.userOptOut)
        case .emptyAuthoredText: .excluded(.missingBody)
        case .noIncomingMessage: .failed(.missingParent, retryable: true)
        case .noGenerationBasis: .failed(.unsupportedEvidenceShape, retryable: false)
        case .reconstructionCopiedSentText: .failed(.reconstructionCopiedSentText, retryable: false)
        case .reconstructionUnsupportedUnit: .failed(.reconstructionUnsupportedUnit, retryable: false)
        case .reconstructionRestatesIncoming: .failed(.reconstructionRestatesIncoming, retryable: false)
        case .reconstructionEmpty: .failed(.reconstructionEmpty, retryable: false)
        case .reconstructionMeaningMismatch: .failed(.reconstructionMeaningMismatch, retryable: false)
        case .exceedsTrainingWindow: .failed(.exceedsTrainingWindow, retryable: false)
        case .incomingHasNoOriginalText: .failed(.incomingHasNoOriginalText, retryable: false)
        }
    }

    // MARK: - Pairs

    /// Writes an example into a pair. `pair` is an existing row when the
    /// evidence is being rebuilt, so its identity and split survive. A task
    /// meaning/rubric change invalidates incorporation in the former lineage;
    /// a renderer-only revision retains the unchanged authored learning.
    @MainActor
    public static func apply(_ example: ComposerWriterTraining.Example, to pair: TrainingPair?,
                             evidence: SentTrainingEvidence, sourceWeight: Double) throws -> TrainingPair {
        let pair = pair ?? TrainingPair(promptText: example.prompt, completionText: example.completion)
        let previousScore = SentMessageStyleScore.decode(pair.measuredStyleScoreJSON)
        let completionChanged = pair.completionText != example.completion
        let retainsVoice = ComposerWriterTraining.hasCurrentLearningSemantics(
            basis: ComposerGenerationBasis.decode(pair.generationBasisJSON), score: previousScore)
            && previousScore == example.measuredStyleScore
            && pair.completionText == example.completion
            && pair.evidenceRevision == evidence.revision
        if pair.promptFormatVersion != TrainingPromptFormat.writerTask && !retainsVoice {
            pair.latestPromotedEvidenceRevision = nil
            pair.latestPromotedCheckpointID = nil
            pair.latestPromotedRunID = nil
            pair.lastReplayedAt = nil
        }
        // A training failure belongs to the input that failed; a rebuilt input
        // (a fit applied to an over-window pair) is eligible again.
        if pair.promptText != example.prompt || completionChanged {
            pair.latestFailedEvidenceRevision = nil
            pair.latestFailedTrainingProfileID = nil
            pair.latestFailedSequenceTokens = nil
        }
        pair.promptText = example.prompt
        pair.completionText = example.completion
        // A synchronous send recording is durable immediately but waits for
        // the bounded model-scoring job before entering an optimizer batch.
        pair.promptFormatVersion = example.measuredStyleScore == nil
            || example.basis.trainingReconstructionVersion != ComposerWriterTraining.reconstructionVersion
            ? TrainingPromptFormat.writerTask - 1 : TrainingPromptFormat.writerTask
        // New text or a new measurement can move the pair to another
        // discovered style: leave it unvisited for the style worker.
        if completionChanged || previousScore != example.measuredStyleScore {
            pair.styleRegisterID = nil
            pair.styleRegisterRevision = nil
        }
        pair.generationBasisJSON = try example.basis.json
        pair.languageID = example.provenance.languageID
        pair.styleControlSnapshot = example.requestedStyleControls
            ?? evidence.sourceOutbox?.styleControlSnapshot ?? pair.styleControlSnapshot
            ?? (evidence.sourceOutbox == nil ? nil : example.basis.request.presentation.controls)
        pair.measuredStyleScoreJSON = example.measuredStyleScore?.json
        pair.styleScoringFailureCount = nil
        pair.styleScoringRetryAfter = nil
        evidence.measuredStyleScoreJSON = example.measuredStyleScore?.json
        evidence.styleScoringFailureCount = nil
        evidence.styleScoringRetryAfter = nil
        pair.styleEvidenceAccountID = evidence.accountID
        pair.styleEvidenceCorrespondentAddress = evidence.correspondentAddress
            ?? example.basis.request.content.to.first
        pair.evidence = evidence
        pair.evidenceRevision = evidence.revision
        pair.sourceWeight = sourceWeight
        pair.message = evidence.sourceMessage ?? pair.message
        pair.replyToMessageId = example.basis.request.content.anchor?.source.messageID ?? pair.replyToMessageId
        switch example.provenance.source {
        case .acceptedSend, .acceptedSendCompiled:
            pair.signalSource = acceptedSendSignalSource
            pair.sourceOutboxID = example.provenance.outboxItemID
            pair.sourceMessageIDNormalized = evidence.normalizedMessageID
        case .historicalReconstruction:
            pair.signalSource = nil
        }
        return pair
    }

    /// Relative weight of an accepted send: an authored email counts once; an
    /// edited model draft counts more, scaled by the approved edit signals.
    @MainActor
    static func sendWeight(_ item: OutboxItem) -> Double {
        let generated = item.draft?.orderedRevisions.contains { $0.triggerRaw != DraftRevisionTrigger.manualEdit } == true
        let signals = TrainingSignal.decodeJSON(item.approvedTrainingSignalsJSON)
        return TrainingSignal.magnitudeWeight(for: signals, baseline: generated ? 3 : 1)
    }

    // MARK: - Preparation job

    /// True when pairs remain at an older prompt format or a preparation
    /// failure is due for another attempt. The scheduler's fallback when the
    /// hot-path snapshot is unavailable.
    @MainActor
    public static func hasRebuildWork(context: ModelContext, now: Date = .now) throws -> Bool {
        let all = try context.fetch(FetchDescriptor<SentTrainingEvidence>())
        return all.contains { isPending($0) || isStale($0) || isRetryDue($0, now: now) || overWindowCandidate($0) }
    }

    /// Sent emails whose first preparation under the current format has not
    /// happened yet: pending (including legacy dispositions), prepared at an
    /// older format, or failed under an older format. Hourly retries of a
    /// failure under the current format are not outstanding — they may never
    /// succeed and must not hold the first full pass.
    @MainActor
    public static func outstandingPreparationCount(context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<SentTrainingEvidence>()).count { evidence in
            isPending(evidence) || isStale(evidence)
                || (evidence.dispositionRaw == SentTrainingEvidenceDisposition.preparationFailed.rawValue
                    && (evidence.preparationTaskVersion ?? 0) < TrainingPromptFormat.current)
        }
    }

    /// Pending preparation, including a disposition written by an older
    /// build that the current ledger no longer names.
    static func isPending(_ evidence: SentTrainingEvidence) -> Bool {
        evidence.dispositionRaw == SentTrainingEvidenceDisposition.pendingPreparation.rawValue
            || SentTrainingEvidenceDisposition(rawValue: evidence.dispositionRaw) == nil
    }

    /// A learnable row whose pair training rejected at its current revision
    /// with a recorded length over the writer window, or with no recorded
    /// length (a rejection before lengths were recorded). Needs no tokenizer;
    /// the scheduler admits rebuild work on it once the model is loaded.
    static func overWindowCandidate(_ evidence: SentTrainingEvidence) -> Bool {
        guard evidence.dispositionRaw == SentTrainingEvidenceDisposition.loraEligible.rawValue else { return false }
        let revision = evidence.revision
        return evidence.trainingPairs.contains { pair in
            pair.evidenceRevision == revision && pair.latestFailedEvidenceRevision == revision
                && (pair.latestFailedSequenceTokens ?? Int.max) > ComposerModelExecutor.writerSequenceLimit
        }
    }

    /// An over-window candidate confirmed for rebuilding: its recorded length
    /// exceeds the window, or, missing a length, the session's tokenizer
    /// measures it once and records it, so no pair is tokenized again.
    @MainActor
    static func exceedsTrainingWindow(_ evidence: SentTrainingEvidence, session: Session) -> Bool {
        guard overWindowCandidate(evidence) else { return false }
        let revision = evidence.revision
        return evidence.trainingPairs.contains { pair in
            guard pair.evidenceRevision == revision, pair.latestFailedEvidenceRevision == revision else { return false }
            if pair.latestFailedSequenceTokens == nil,
               let prompt = try? session.window.promptTokens(pair.promptText),
               let completion = try? session.window.trainingCompletionTokens(pair.completionText) {
                pair.latestFailedSequenceTokens = prompt + completion
            }
            return (pair.latestFailedSequenceTokens ?? 0) > ComposerModelExecutor.writerSequenceLimit
        }
    }

    static func isStale(_ evidence: SentTrainingEvidence) -> Bool {
        guard evidence.dispositionRaw == SentTrainingEvidenceDisposition.loraEligible.rawValue else { return false }
        let revision = evidence.revision
        return evidence.trainingPairs.contains { pair in
            pair.evidenceRevision == revision && pair.promptFormatVersion < TrainingPromptFormat.current
        }
    }

    /// A retryable failure is due again after `preparationRetryInterval`; a
    /// failure recorded under an older prompt format is due once under the
    /// current one.
    static func isRetryDue(_ evidence: SentTrainingEvidence, now: Date) -> Bool {
        guard evidence.dispositionRaw == SentTrainingEvidenceDisposition.preparationFailed.rawValue else { return false }
        // Rejected under the earlier notes reserve: decided again once under
        // the bounded reserve, which records `exceedsTrainingWindow` if it
        // still cannot fit.
        if evidence.reason == .exceedsWriterWindow { return true }
        if (evidence.preparationTaskVersion ?? 0) < TrainingPromptFormat.current { return true }
        guard evidence.isRetryable else { return false }
        let attempted = evidence.preparationAttemptedAt ?? .distantPast
        return now.timeIntervalSince(attempted) >= SentTrainingEvidence.preparationRetryInterval
    }

    /// Drains pending evidence, rebuilds pairs left at an older prompt format
    /// and retries due failures, at most `batchSize` rows and
    /// `reconstructionsPerJob` model calls per job. Rows that need the model
    /// wait when none is loaded or the budget is spent. Returns the number of
    /// evidence rows finalized.
    @MainActor
    public func buildPendingPairs(context: ModelContext, batchSize: Int, engine: (any TrainingEngine)? = nil,
                                  now: Date = .now,
                                  shouldYield: @escaping @MainActor @Sendable () -> Bool = { false }) async throws -> Int {
        guard batchSize > 0 else { return 0 }
        let all = try context.fetch(FetchDescriptor<SentTrainingEvidence>())
        func newest(_ lhs: SentTrainingEvidence, _ rhs: SentTrainingEvidence) -> Bool {
            let leftDate = lhs.sentAt ?? lhs.createdAt
            let rightDate = rhs.sentAt ?? rhs.createdAt
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let pending = all.filter(Self.isPending).sorted(by: newest)
        let stale = all.filter(Self.isStale).sorted(by: newest)
        let retries = all.filter { Self.isRetryDue($0, now: now) }.sorted(by: newest)
        let session = Session(engine: engine, shouldYield: shouldYield)
        let queued = pending + stale + retries
        // Rebuilding over-window pairs needs the model; it fills only room the
        // batch has left.
        var overWindow: [SentTrainingEvidence] = []
        if queued.count < batchSize, session.engine != nil, session.window.isTokenizerLoaded {
            let queuedIDs = Set(queued.map(\.id))
            overWindow = all.filter { !queuedIDs.contains($0.id) && Self.exceedsTrainingWindow($0, session: session) }
                .sorted(by: newest)
        }
        let batch = (queued + overWindow).prefix(batchSize)
        guard !batch.isEmpty else {
            // Lengths measured for pairs that turned out to fit are kept, so
            // admission does not bring them back.
            if context.hasChanges { try context.save() }
            return 0
        }
        var finalizedCount = 0

        for evidence in batch {
            guard !session.needsToYield() else { break }
            // Historical mail has gates that need no model: unusable rows
            // terminate before any reconstruction is spent on them.
            if Self.isPending(evidence), evidence.sourceOutbox == nil {
                guard let message = evidence.sourceMessage else {
                    finalize(evidence, disposition: .preparationFailed, reason: .unsupportedEvidenceShape, retryable: false)
                    finalizedCount += 1
                    continue
                }
                if message.isTrashed {
                    finalize(evidence, disposition: .excluded, reason: .trashedSource); finalizedCount += 1; continue
                }
                if evidence.learningPreference == .explicitDisabled || evidence.learningPreference == .automaticDisabled {
                    finalize(evidence, disposition: .excluded, reason: .userOptOut); finalizedCount += 1; continue
                }
                if message.isAutomatedOrBulk == true {
                    finalize(evidence, disposition: .excluded, reason: .automatedResponse); finalizedCount += 1; continue
                }
                if evidence.kind != .historicalReply && evidence.kind != .historicalStandalone {
                    finalize(evidence, disposition: .preparationFailed, reason: .unsupportedEvidenceShape, retryable: false)
                    finalizedCount += 1
                    continue
                }
            }
            if try await projectAndFinalize(evidence, session: session, context: context) {
                finalizedCount += 1
            }
        }
        try context.save()
        return finalizedCount
    }

    /// Projects one row and writes the outcome. Returns false when the row
    /// needs the model and none is available, a reconstruction was interrupted,
    /// or the evidence changed underneath a long model call.
    @MainActor
    private func projectAndFinalize(_ evidence: SentTrainingEvidence, session: Session, context: ModelContext) async throws -> Bool {
        let revision = evidence.revision
        let outcome = await project(evidence, session: session, context: context)
        // Ingest may have re-keyed the evidence while the model ran; the
        // projection was built from the old text and is not written.
        guard evidence.revision == revision else { return false }
        switch outcome {
        case .needsModel, .interrupted:
            return false
        case .example(let example):
            // A rebuild that reproduces the input training rejected for its
            // length cannot fit; it ends terminally instead of rebuilding on
            // every job.
            let reproducesOverWindowInput = evidence.trainingPairs.contains { pair in
                pair.evidenceRevision == revision && pair.latestFailedEvidenceRevision == revision
                    && (pair.latestFailedSequenceTokens ?? 0) > ComposerModelExecutor.writerSequenceLimit
                    && pair.promptText == example.prompt && pair.completionText == example.completion
            }
            if reproducesOverWindowInput {
                for pair in evidence.trainingPairs { context.delete(pair) }
                finalize(evidence, disposition: .preparationFailed, reason: .exceedsTrainingWindow, retryable: false)
                return true
            }
            // Every pair of the evidence collapses to one: a send that once
            // recorded an instruction-shaped and a reply-shaped pair, or a
            // row left at an older revision when the evidence was re-keyed.
            // The survivor keeps its identity and split; a current-revision
            // row wins, then the row that carries style or send provenance.
            let current = evidence.trainingPairs.sorted { lhs, rhs in
                let leftCurrent = lhs.evidenceRevision == evidence.revision
                let rightCurrent = rhs.evidenceRevision == evidence.revision
                if leftCurrent != rightCurrent { return leftCurrent }
                let leftRank = (lhs.stylePreferenceEventID != nil ? 2 : 0) + (lhs.sourceEventKey != nil ? 1 : 0)
                let rightRank = (rhs.stylePreferenceEventID != nil ? 2 : 0) + (rhs.sourceEventKey != nil ? 1 : 0)
                if leftRank != rightRank { return leftRank > rightRank }
                return lhs.createdAt < rhs.createdAt
            }
            let weight = evidence.sourceOutbox.map(Self.sendWeight)
                ?? (TrivialReplyFilter.classify(TrainingPromptFormatter.storedCompletionBody(example.completion)) == .lowWeight ? 0.5 : 1)
            let pair = try Self.apply(example, to: current.first, evidence: evidence, sourceWeight: weight)
            if current.isEmpty {
                pair.trainingRoleRaw = evidence.trainingPairs.compactMap(\.trainingRoleRaw).first
                context.insert(pair)
            }
            for duplicate in current.dropFirst() { context.delete(duplicate) }
            finalize(evidence, disposition: .loraEligible)
        case .excluded(let reason):
            for pair in evidence.trainingPairs { context.delete(pair) }
            finalize(evidence, disposition: .excluded, reason: reason)
        case .failed(let reason, let retryable):
            if !retryable { for pair in evidence.trainingPairs { context.delete(pair) } }
            finalize(evidence, disposition: .preparationFailed, reason: reason, retryable: retryable)
        }
        return true
    }

    func finalize(
        _ evidence: SentTrainingEvidence,
        disposition: SentTrainingEvidenceDisposition,
        reason: SentTrainingEvidenceReason? = nil,
        retryable: Bool = false,
        now: Date = .now
    ) {
        evidence.disposition = disposition
        evidence.reason = reason
        evidence.preparationAttemptedAt = now
        evidence.dispositionedAt = now
        evidence.isRetryable = retryable
        evidence.preparationTaskVersion = TrainingPromptFormat.current
        evidence.updatedAt = now
        evidence.sourceMessage?.trainingStatus = disposition == .preparationFailed
            ? .failed
            : .completed
    }
}
