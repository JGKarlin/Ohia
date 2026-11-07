import Foundation
import SwiftData
import OhiaCore

/// Freezes everything one generation depends on into a value snapshot: sending
/// identity, recipients, language, every recorded instruction in order, manual
/// edits since the generated revision the editor text derives from, role-tagged
/// evidence and the effective presentation controls. No SwiftData object
/// crosses an await.
public enum ComposerGenerationRequestCompiler {
    /// Compile for an existing draft (reply or compose). `pack` is the
    /// token-bounded evidence the caller already packed with the production
    /// packer; `window` fits that evidence to the writer window (see
    /// `ComposerWriterWindow`); `currentBody` is the editor text, from which
    /// manual edits since the last generated revision are derived;
    /// `instruction` is a typed revision instruction not yet recorded as a
    /// revision.
    @MainActor
    public static func compile(
        draft: Draft, context: ModelContext, pack: ComposerContextPack, window: ComposerWriterWindow,
        currentBody: String? = nil, instruction: String? = nil, rules: [String] = []
    ) throws -> ComposerGenerationRequest {
        try request(from: writerWindowFit(draft: draft, context: context, pack: pack, window: window,
            currentBody: currentBody, instruction: instruction, rules: rules))
    }

    /// The writer fit for the draft's generation without throwing when the
    /// essentials exceed the window: the fitted request, the source-context
    /// meter and the sources the writer leaves out. The pipeline renders
    /// with the draft's cached brief when it still applies, so the fit
    /// measures with it too.
    @MainActor
    public static func writerWindowFit(
        draft: Draft, context: ModelContext, pack: ComposerContextPack, window: ComposerWriterWindow,
        currentBody: String? = nil, instruction: String? = nil, rules: [String] = []
    ) throws -> ComposerWriterWindow.Fit {
        let inputs = try fitInputs(draft: draft, context: context, pack: pack,
            currentBody: currentBody, instruction: instruction, rules: rules)
        return try window.fit(inputs.request, retention: inputs.retention, cachedBrief: inputs.cachedBrief)
    }

    /// The draft's writer measurement, reusing `previous` when nothing the
    /// fit depends on changed.
    @MainActor
    public static func writerWindowUsage(
        draft: Draft, context: ModelContext, pack: ComposerContextPack, window: ComposerWriterWindow,
        currentBody: String?, instruction: String?, previous: ComposerWriterWindowUsage?
    ) throws -> ComposerWriterWindowUsage {
        let inputs = try fitInputs(draft: draft, context: context, pack: pack,
            currentBody: currentBody, instruction: instruction, rules: [])
        if let previous, previous.requestFingerprint
            == (try ComposerWriterWindow.fingerprint(inputs.request, retention: inputs.retention, limits: .drafting)) {
            return previous
        }
        return try window.fit(inputs.request, retention: inputs.retention, cachedBrief: inputs.cachedBrief).usage
    }

    @MainActor
    private static func fitInputs(
        draft: Draft, context: ModelContext, pack: ComposerContextPack,
        currentBody: String?, instruction: String?, rules: [String]
    ) throws -> (request: ComposerGenerationRequest, retention: ComposerWriterWindow.Retention,
                 cachedBrief: ComposerContentBrief?) {
        let request = try unfitted(draft: draft, context: context, pack: pack,
            currentBody: currentBody, instruction: instruction, rules: rules)
        let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON)
        // Decision-research sources join the writer's evidence without a row
        // in Composer, so the author cannot see or swap them.
        let listed = Set(ComposerSourceCoding.decode(draft.sourcesJSON).map(\.id))
        let hidden = Set(request.content.evidence.map(\.source.id)).subtracting(listed)
        return (request, .from(state, hiddenSourceIDs: hidden), DraftOrchestrator.cachedBrief(for: draft))
    }

    /// The fitted request, or the terminal error naming why the content that
    /// is never left out cannot fit.
    public static func request(from fit: ComposerWriterWindow.Fit) throws -> ComposerGenerationRequest {
        guard fit.fits else { throw ComposerContentError.writerWindowExceeded(fit.usage.overflow ?? .sources) }
        return fit.request
    }

    @MainActor
    private static func unfitted(
        draft: Draft, context: ModelContext, pack: ComposerContextPack,
        currentBody: String?, instruction: String?, rules: [String]
    ) throws -> ComposerGenerationRequest {
        let message = draft.message
        let accountID = message?.accountID ?? message?.account?.id ?? draft.composeFromAccountID
        let account = try resolveAccount(attached: message?.account, accountID: accountID, context: context)
        let sender = Self.sender(identity: account?.resolveIdentity(for: draft.fromIdentityID), account: account)
        // A draft that names an account must resolve a sending address from
        // it; a removed or disconnected account cannot author as "the author".
        guard accountID == nil || !sender.address.isEmpty else {
            throw ComposerContentError.invalidRequest("The selected sending identity is unavailable.")
        }
        let recipients = message == nil
            ? ReplyRecipientSet(to: ComposeAddressEncoding.decode(draft.composeToJSON),
                cc: ComposeAddressEncoding.decode(draft.composeCcJSON), bcc: ComposeAddressEncoding.decode(draft.composeBccJSON))
            : ReplyRecipientPolicy.effectiveRecipients(for: draft)
        let subject = message?.subject ?? draft.composeSubject ?? ""
        let language = message.flatMap { DraftLanguage.resolvedID(for: $0) }
            ?? DraftLanguage.familyID(for: draft.languageID)
            ?? RecipientDraftLanguageResolver.preferredLanguage(accountID: accountID,
                correspondentAddress: recipients.to.first ?? "", context: context) ?? "und"
        let selected = try selectedSources(draft.sourcesJSON)
        let input = ComposerInterviewDraftInputCompiler.compile(draft: draft,
            framing: message == nil ? .compose : .reply, selectedSources: selected)
        var events: [(date: Date, requirement: ComposerRequirement)] = []
        func add(_ text: String?, id: String, origin: ComposerRequirement.Origin,
                 question: String? = nil, date: Date = .distantFuture) {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            events.append((date, ComposerRequirement(id: id, origin: origin, sequence: events.count,
                originalText: text, questionText: question)))
        }
        // Preserve every recorded user instruction verbatim, without the old
        // 12-item/8,000-character tail projection silently dropping requirements.
        for revision in draft.orderedRevisions where revision.triggerRaw != DraftRevisionTrigger.manualEdit {
            if let text = revision.instruction, !isPresentationOperation(text) {
                add(text, id: "revision:\(revision.id.uuidString)", origin: .revisionInstruction, date: revision.createdAt)
            }
        }
        let history = ComposerDecisionHistoryPersistence.decode(draft.decisionHistoryJSON)
        let liveTranscript = ComposerInterviewStateCoding.decode(draft.interviewStateJSON)
            .map { ComposerInterviewExecutor.project($0).transcript } ?? []
        for decision in input.acceptedDecisions {
            let liveAnswers = liveTranscript.filter {
                $0.node.id == decision.nodeID && $0.node.text == decision.questionText
                    && $0.node.variableID == decision.variableID
            }.compactMap(\.answer)
            add(decision.answerText,
                id: "answer:\(decision.nodeID)", origin: .interviewAnswer,
                question: decision.questionText,
                date: Self.decisionDate(decision, history: history, liveAnswers: liveAnswers))
        }
        let guidance = message == nil ? draft.composeInstruction : draft.draftingInstruction
        let guidanceDate = try guidance.map {
            try Self.guidanceDate($0, history: history, hasRevisions: !draft.orderedRevisions.isEmpty)
        } ?? .distantFuture
        add(guidance, id: "guidance:current", origin: .draftGuidance, date: guidanceDate)
        // Feedback the user attached when rejecting the previous draft is the
        // newest instruction; the orchestrator clears it once a draft persists.
        add(message?.regenerationFeedback, id: "feedback:regeneration", origin: .draftGuidance)
        if let instruction, !isPresentationOperation(instruction) {
            add(instruction, id: pendingInstructionID, origin: .revisionInstruction)
        }
        let generated = draft.baseGeneratedRevision
        var manualEdits = try manualHistory(draft: draft, currentBody: currentBody)
        // Requirements and recorded edits share one timeline. A rewrite's
        // completion time never redates the decisions in its frozen basis.
        // An uncaptured edit remains unordered instead of pretending to be
        // later than a typed instruction whose ordering is known.
        struct Event {
            var date: Date
            var requirementIndex: Int?
            var manualIndices: [Int]
            var insertionOrder: Int
        }
        var timeline = events.enumerated().map {
            Event(date: $0.element.date, requirementIndex: $0.offset,
                  manualIndices: [], insertionOrder: $0.offset)
        }
        for (index, edit) in manualEdits.enumerated() {
            manualEdits[index].sequence = nil
            guard let date = edit.authoredAt else { continue }
            if let eventIndex = timeline.firstIndex(where: { event in
                guard let other = event.manualIndices.first else { return false }
                return event.date == date
                    && manualEdits[other].authoredRevisionID == edit.authoredRevisionID
            }) {
                timeline[eventIndex].manualIndices.append(index)
            } else {
                timeline.append(Event(date: date, requirementIndex: nil,
                    manualIndices: [index], insertionOrder: timeline.count))
            }
        }
        timeline.sort { $0.date == $1.date ? $0.insertionOrder < $1.insertionOrder : $0.date < $1.date }
        var requirements: [ComposerRequirement] = []
        for (sequence, event) in timeline.enumerated() {
            if let index = event.requirementIndex {
                var requirement = events[index].requirement
                requirement.sequence = sequence
                requirements.append(requirement)
            }
            for index in event.manualIndices { manualEdits[index].sequence = sequence }
        }
        let register: StyleRegister?
        if let id = draft.pendingStyleRegisterID ?? draft.styleRegisterID {
            register = StyleRegisterResolver.register(withID: id, language: language, context: context)
        } else if let message {
            register = StyleRegisterResolver.resolve(forIncoming: message, language: language, context: context)
        } else {
            register = StyleRegisterResolver.resolve(forComposeRecipient: recipients.to.first ?? "",
                language: language, context: context)
        }
        // A style picked after these controls were decided starts from its
        // own defaults, not the previous style's sliders.
        let controls = draft.styleControlSnapshot(includingPending: true).flatMap { snapshot in
            draft.pendingStyleRegisterID == nil || snapshot.registerID == register?.id ? snapshot : nil
        } ?? .inherited(registerID: register?.id, registerRevision: register?.revision, defaults: register?.styleAxes ?? ComposerStyleRubric.neutral)
        var request = try assemble(mode: message == nil ? .compose : .reply, message: message, account: account,
            sender: sender, recipients: recipients, subject: subject, language: language, pack: pack,
            requirements: requirements, unknowns: input.deferredVariableLines, manualEdits: manualEdits,
            rules: rules, register: register, controls: controls, currentBody: currentBody,
            displayedRevisionID: generated?.id,
            replyPlanTexts: Self.replyPlanTexts(input.replyContext, pack: pack, subject: subject),
            incomingReading: Self.incomingReading(input.replyContext, pack: pack, subject: subject),
            context: context)
        // A pending slider decision this pass consumes moves Length from the
        // draft's applied one; a draft prepared before any slider was set
        // was written with its style's defaults.
        if currentBody != nil, let pending = draft.pendingStyleControlSnapshot,
           controls.decisionID == pending.decisionID {
            let applied = (draft.styleControlSnapshot?.effectiveAxes ?? pending.baseAxes
                ?? register?.styleAxes ?? ComposerStyleRubric.neutral).detail
            request.presentation.previousLengthPoint = ComposerPresentationInput.lengthPoint(applied)
        }
        return request
    }

    /// Compile for a reply prepared in the background before any Draft exists:
    /// the default reply identity and recipients, the message's language, the
    /// prepared interview's accepted answers and the prepared sources, fitted
    /// to the writer window.
    @MainActor
    public static func compile(
        message: Message, sources: [ComposerSource], interviewState: ComposerInterviewState,
        pack: ComposerContextPack, window: ComposerWriterWindow, context: ModelContext, rules: [String] = []
    ) throws -> ComposerGenerationRequest {
        try request(from: writerWindowFit(message: message, sources: sources, interviewState: interviewState,
            pack: pack, window: window, context: context, rules: rules))
    }

    /// The prepared reply's writer fit without throwing when the essentials
    /// exceed the window.
    @MainActor
    public static func writerWindowFit(
        message: Message, sources: [ComposerSource], interviewState: ComposerInterviewState,
        pack: ComposerContextPack, window: ComposerWriterWindow, context: ModelContext, rules: [String] = []
    ) throws -> ComposerWriterWindow.Fit {
        let request = try unfitted(message: message, sources: sources, interviewState: interviewState,
            pack: pack, context: context, rules: rules)
        return try window.fit(request, retention: .from(interviewState))
    }

    @MainActor
    private static func unfitted(
        message: Message, sources: [ComposerSource], interviewState: ComposerInterviewState,
        pack: ComposerContextPack, context: ModelContext, rules: [String]
    ) throws -> ComposerGenerationRequest {
        let accountID = message.accountID ?? message.account?.id
        let account = try resolveAccount(attached: message.account, accountID: accountID, context: context)
        let sender = Self.sender(identity: IdentityResolver.resolveReplyIdentity(message: message)
            ?? account?.resolveIdentity(for: nil), account: account)
        guard accountID == nil || !sender.address.isEmpty else {
            throw ComposerContentError.invalidRequest("The selected sending identity is unavailable.")
        }
        let recipients = ReplyRecipientPolicy.defaultRecipients(for: message, mode: .reply)
        let language = DraftLanguage.resolvedID(for: message) ?? "und"
        let input = ComposerInterviewDraftInputCompiler.compile(state: interviewState, framing: .reply,
            selectedSources: sources, draftGuidance: nil)
        var requirements: [ComposerRequirement] = []
        for decision in input.acceptedDecisions {
            guard let text = decision.answerText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            requirements.append(ComposerRequirement(id: "answer:\(decision.nodeID)", origin: .interviewAnswer,
                sequence: requirements.count, originalText: text, questionText: decision.questionText))
        }
        let register = StyleRegisterResolver.resolve(forIncoming: message, language: language, context: context)
        let controls = StyleControlSnapshot.inherited(registerID: register?.id, registerRevision: register?.revision,
            defaults: register?.styleAxes ?? ComposerStyleRubric.neutral)
        return try assemble(mode: .reply, message: message, account: account, sender: sender,
            recipients: recipients, subject: message.subject, language: language, pack: pack,
            requirements: requirements, unknowns: input.deferredVariableLines, manualEdits: [],
            rules: rules, register: register, controls: controls, currentBody: nil,
            displayedRevisionID: nil,
            replyPlanTexts: Self.replyPlanTexts(input.replyContext, pack: pack, subject: message.subject),
            incomingReading: Self.incomingReading(input.replyContext, pack: pack, subject: message.subject),
            context: context)
    }

    /// Compile a training request for historical authored mail whose content
    /// units were reconstructed from the sent text. The incoming message is
    /// the one the reply answered; earlier thread mail is context with roles
    /// from message direction. The measured final-text axes condition the
    /// completion; these observations never claim to be user slider choices.
    /// The evidence is fitted to the writer window within `limits` (the
    /// training window less the known completion), so a reconstruction reads
    /// exactly the correspondence its training prompt shows.
    @MainActor
    public static func compile(
        reconstructedFor sent: Message, incoming: Message?, instructions: [String],
        pack: ComposerContextPack, window: ComposerWriterWindow, limits: ComposerWriterWindow.Limits,
        context: ModelContext, measuredAxes: StyleAxisValues? = nil
    ) throws -> ComposerGenerationRequest {
        try request(from: window.fit(try unfitted(reconstructedFor: sent, incoming: incoming,
            instructions: instructions, pack: pack, context: context, measuredAxes: measuredAxes),
            retention: .none, limits: limits))
    }

    @MainActor
    private static func unfitted(
        reconstructedFor sent: Message, incoming: Message?, instructions: [String],
        pack: ComposerContextPack, context: ModelContext, measuredAxes: StyleAxisValues?
    ) throws -> ComposerGenerationRequest {
        let accountID = sent.accountID ?? sent.account?.id ?? incoming?.accountID ?? incoming?.account?.id
        let account = try resolveAccount(attached: sent.account ?? incoming?.account, accountID: accountID, context: context)
        let identity = account?.identities.first(where: { $0.address.lowercased() == sent.fromAddress.lowercased() })
            ?? incoming.flatMap { IdentityResolver.resolveReplyIdentity(message: $0) } ?? account?.resolveIdentity(for: nil)
        var sender = Self.sender(identity: identity, account: account)
        if sender.address.isEmpty || sender.address.lowercased() != sent.fromAddress.lowercased() {
            sender = Sender(address: sent.fromAddress, displayName: sent.fromName?.isEmpty == false ? sent.fromName : sender.displayName)
        }
        let sentRecipients = sent.participants.sorted { ($0.headerPosition ?? 0) < ($1.headerPosition ?? 0) }
        let to = sentRecipients.filter { $0.role == .to }.compactMap { $0.participant?.emailAddress }
        let recipients = ReplyRecipientSet(to: to.isEmpty ? incoming.map { ReplyRecipientPolicy.defaultRecipients(for: $0, mode: .reply).to } ?? [] : to,
            cc: sentRecipients.filter { $0.role == .cc }.compactMap { $0.participant?.emailAddress }, bcc: [])
        let language = DraftLanguage.familyID(for: sent.languageDetected)
            ?? incoming.flatMap { DraftLanguage.resolvedID(for: $0) } ?? "und"
        let requirements = instructions.enumerated().map { index, text in
            ComposerRequirement(id: "reconstructed:\(index + 1)", origin: .reconstructed, sequence: index,
                originalText: text, questionText: nil)
        }
        let register = incoming.flatMap { StyleRegisterResolver.resolve(forIncoming: $0, language: language, context: context) }
            ?? StyleRegisterResolver.resolve(forComposeRecipient: recipients.to.first ?? "",
                language: language, context: context)
        let controls = StyleControlSnapshot.inherited(registerID: register?.id,
            registerRevision: register?.revision, defaults: measuredAxes ?? ComposerStyleRubric.neutral)
        return try assemble(mode: incoming == nil ? .compose : .reply, message: incoming, account: account, sender: sender,
            recipients: recipients, subject: sent.subject, language: language, pack: pack,
            requirements: requirements, unknowns: [], manualEdits: [], rules: [], register: register,
            controls: controls, currentBody: nil, displayedRevisionID: nil, context: context)
    }

    // MARK: - Shared

    /// Follow the selected body's actual ancestry, never the newest revision
    /// in another branch. A generated body carries its input author history;
    /// a manual snapshot adds only the change from its recorded parent.
    @MainActor
    private static func manualHistory(draft: Draft, currentBody: String?) throws -> [ComposerManualEdit] {
        let revisions = Dictionary(uniqueKeysWithValues: draft.orderedRevisions.map { ($0.id, $0) })
        let base: DraftRevision?
        if let id = draft.baseRevisionID {
            guard let recorded = revisions[id] else {
                throw ComposerContentError.invalidRequest("The displayed draft's recorded revision is unavailable.")
            }
            base = recorded
        } else {
            base = draft.baseGeneratedRevision
        }
        guard let base else { return [] }
        var visited: Set<UUID> = []
        func history(of revision: DraftRevision) throws -> [ComposerManualEdit] {
            guard visited.insert(revision.id).inserted else {
                throw ComposerContentError.invalidRequest("The draft's recorded edit ancestry contains a cycle.")
            }
            guard revision.triggerRaw == DraftRevisionTrigger.manualEdit else {
                guard let recorded = revision.generationBasisJSON else { return [] }
                guard let basis = ComposerGenerationBasis.decode(recorded) else {
                    throw ComposerContentError.invalidRequest("The draft's recorded author history is unreadable.")
                }
                return basis.request.content.manualEdits.filter { !$0.isLayoutOnly }
            }
            guard let id = revision.baseRevisionID, let parent = revisions[id] else {
                throw ComposerContentError.invalidRequest("A manual edit's recorded parent is unavailable.")
            }
            return try history(of: parent) + ComposerManualEdit.capture(
                original: parent.bodyText, edited: revision.bodyText, baseRevisionID: parent.id,
                authoredRevisionID: revision.id, authoredAt: revision.createdAt)
        }
        var edits = try history(of: base)
        if let currentBody, currentBody != base.bodyText {
            edits += try ComposerManualEdit.capture(original: base.bodyText, edited: currentBody,
                baseRevisionID: base.id)
        }
        return edits
    }

    @MainActor
    private static func assemble(
        mode: ComposerContentInput.Mode, message: Message?, account: Account?, sender: Sender,
        recipients: ReplyRecipientSet, subject: String, language: String, pack: ComposerContextPack,
        requirements: [ComposerRequirement], unknowns: [String], manualEdits: [ComposerManualEdit],
        rules: [String], register: StyleRegister?, controls: StyleControlSnapshot?, currentBody: String?,
        displayedRevisionID: UUID?, replyPlanTexts: [String]? = nil,
        incomingReading: ComposerIncomingReading? = nil, context: ModelContext
    ) throws -> ComposerGenerationRequest {
        // A reply to a pure forward would answer nothing: the email has text,
        // but none of its own for the writer to read.
        if mode == .reply, let message, pack.anchorText.isEmpty,
           QuestionGroundingContextPacking.hasOnlyQuotedText(message) {
            throw ComposerContentError.incomingHasNoOriginalText
        }
        let ownAddresses = Set((account?.identities ?? []).map { $0.address.lowercased() }
            + [sender.address.lowercased(), account?.emailAddress.lowercased() ?? ""]).filter { !$0.isEmpty }
        let evidence = try pack.sources.map { source -> ComposerEvidence in
            var backing: Message?
            if let id = source.messageID {
                backing = try context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })).first
            }
            return ComposerEvidence(source: source,
                role: Self.role(of: source, backing: backing, ownAddresses: ownAddresses),
                authorAddress: backing?.fromAddress, authorDisplayName: backing?.fromName,
                authoredAt: backing?.sentAt ?? backing?.receivedAt, exactText: source.snippet,
                recipientAddresses: backing.map(Self.recipientAddresses))
        }
        let anchor: ComposerEvidence?
        if let message, !pack.anchorText.isEmpty {
            let source = ComposerSource(id: message.id, kind: .thread, label: message.subject,
                snippet: pack.anchorText, messageID: message.id, addedAt: Date(timeIntervalSince1970: 0))
            anchor = ComposerEvidence(source: source, role: .incoming, authorAddress: message.fromAddress,
                authorDisplayName: message.fromName, authoredAt: message.sentAt ?? message.receivedAt,
                exactText: pack.anchorText)
        } else { anchor = nil }
        let effectiveControls = controls?.effectiveAxes == nil
            ? StyleControlSnapshot.inherited(registerID: register?.id, registerRevision: register?.revision,
                defaults: register?.styleAxes ?? ComposerStyleRubric.neutral) : controls
        // A follow-up to the author's own email (sent from any of their
        // addresses) answers no one who replied: nothing reads as repeating.
        let answersSomeoneElse = message.map { !ownAddresses.contains($0.fromAddress.lowercased()) } ?? false
        let request = ComposerGenerationRequest(content: ComposerContentInput(
            mode: mode, identityAddress: sender.address,
            authorDisplayName: sender.displayName, to: recipients.to, cc: recipients.cc, bcc: recipients.bcc,
            languageID: language, subject: subject, anchor: anchor, requirements: requirements,
            unknowns: unknowns, evidence: evidence, manualEdits: manualEdits, rules: rules,
            replyPlanTexts: answersSomeoneElse ? replyPlanTexts : nil,
            incomingReading: mode == .reply ? incomingReading : nil),
            presentation: ComposerPresentationInput(registerID: register?.id, registerName: register?.name,
                registerRevision: register?.revision, controls: effectiveControls), currentBody: currentBody,
            displayedRevisionID: displayedRevisionID, requestID: UUID())
        try request.content.validate()
        return request
    }

    struct Sender {
        let address: String
        let displayName: String?
    }

    /// The identity row when there is one; otherwise the account sends as
    /// itself; with no account at all the author is unnamed and the request
    /// still compiles (the writer addresses "the author").
    static func sender(identity: Identity?, account: Account?) -> Sender {
        if let identity {
            return Sender(address: identity.address, displayName: identity.displayName?.isEmpty == false ? identity.displayName : nil)
        }
        if let account {
            return Sender(address: account.emailAddress, displayName: account.displayName.isEmpty ? nil : account.displayName)
        }
        return Sender(address: "", displayName: nil)
    }

    @MainActor
    private static func resolveAccount(attached: Account?, accountID: UUID?, context: ModelContext) throws -> Account? {
        if let attached { return attached }
        guard let accountID else { return nil }
        return try context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == accountID })).first
    }

    private static func selectedSources(_ json: String?) throws -> [ComposerSource] {
        guard let json else { return [] }
        do { return try JSONDecoder().decode([ComposerSource].self, from: Data(json.utf8)) }
        catch { throw ComposerContentError.invalidRequest("The selected source records could not be decoded.") }
    }

    /// The author's own earlier mail is history the current instructions
    /// override; a correspondent's mail is attributed context; everything else
    /// is an external source. Decided from account identities and message
    /// direction, never from content.
    static func role(of source: ComposerSource, backing: Message?, ownAddresses: Set<String>) -> ComposerEvidenceRole {
        if source.authoredByUser == true || backing?.isSentByUser == true || source.kind == .pastReply {
            return .authorPrior
        }
        if let address = backing?.fromAddress.lowercased(), ownAddresses.contains(address) { return .authorPrior }
        switch source.kind {
        case .thread, .email, .retrieved, .threadState, .messages: return .correspondent
        default: return .external
        }
    }

    /// What the reply plan read as asked: each request it quoted from the
    /// email being answered, whatever it found for it, and the earlier
    /// passages it found answering one. Nil when no plan read this email's
    /// requests: none yet, one prepared before it recorded them, or one made
    /// for another email or other sources (`pack` is what the draft is
    /// written from now). Empty when it found no request.
    /// The reading of the email being answered the current plan made, for
    /// this very email and its sources, by the current reading prompt.
    static func incomingReading(_ review: ComposerReplyContextReview?, pack: ComposerContextPack,
                                subject: String) -> ComposerIncomingReading? {
        guard let review, review.contextFingerprint == ComposerReplyContextReview.fingerprint(
            anchor: pack.anchorText, sources: pack.sources, subject: subject),
              review.incomingReading?.version == ComposerIncomingReading.currentVersion else { return nil }
        return review.incomingReading
    }

    static func replyPlanTexts(_ review: ComposerReplyContextReview?, pack: ComposerContextPack,
                               subject: String) -> [String]? {
        guard let review, let items = review.responseItems,
              review.contextFingerprint == ComposerReplyContextReview.fingerprint(
                  anchor: pack.anchorText, sources: pack.sources, subject: subject) else { return nil }
        let asked = items.map(\.request) + review.questions.compactMap(\.anchorQuote)
        let answers = items.filter { $0.status == .supported }.flatMap { $0.evidence.map(\.quote) }
        var seen = Set<String>()
        return (asked + answers).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }
    }

    /// Who a stored email went to: its To and Cc addresses, lowercased.
    static func recipientAddresses(of message: Message) -> [String] {
        var seen = Set<String>()
        return message.participants
            .filter { $0.role == .to || $0.role == .cc }
            .compactMap { $0.participant?.emailAddress.lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The requirement a revision's newly typed instruction is recorded as.
    static let pendingInstructionID = "revision:pending"

    static func isPresentationOperation(_ text: String) -> Bool {
        text == DraftGenerationOrchestrator.regenerationInstruction
            || text == DraftGenerationOrchestrator.restyleInstruction
            || text.hasPrefix("Revise the current draft in place to apply only the style-control changes listed below.")
    }

    /// A source-only Decisions snapshot must not reassert old draft guidance.
    /// A different current brief is pending user input. Without any recorded
    /// guidance basis, order against existing revisions is unknown.
    static func guidanceDate(_ guidance: String, history: ComposerDecisionHistory?, hasRevisions: Bool) throws -> Date {
        let normalized = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .distantFuture }
        guard let history, let active = history.versions.firstIndex(where: { $0.id == history.activeVersionID }),
              let captured = history.versions[active].draftGuidance else {
            guard !hasRevisions else {
                throw ComposerContentError.invalidRequest("The draft guidance has no recorded order relative to this draft's revisions.")
            }
            return .distantFuture
        }
        guard captured.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else { return .distantFuture }
        var first = active
        while first > 0, history.versions[first - 1].draftGuidance?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized {
            first -= 1
        }
        return history.versions[first].createdAt
    }

    /// Re-evaluating sources can carry an unchanged answer into a newer
    /// Decisions version. Its authority remains at the version where that
    /// answer last changed, so source refresh never reverses a typed revision.
    static func decisionDate(_ decision: ComposerInterviewAcceptedDecision,
                             history: ComposerDecisionHistory?,
                             liveAnswers: [ComposerInterviewAnswer] = []) -> Date {
        // The accepted live answer records the author event itself. A missing
        // history snapshot must not turn a newly committed answer into the
        // oldest input. Carried decisions without a matching live answer use
        // their recorded history below.
        if let committed = liveAnswers.filter({ $0.nodeID == decision.nodeID && !$0.skipped })
            .map(\.committedAt).max() {
            return committed
        }
        guard let history, let active = history.versions.firstIndex(where: { $0.id == history.activeVersionID }) else {
            return .distantPast
        }
        func contains(_ version: ComposerDecisionVersion) -> Bool {
            ComposerInterviewDraftInputCompiler.compile(state: version.interviewState,
                framing: .reply, selectedSources: [], draftGuidance: nil).acceptedDecisions.contains {
                    $0.questionText == decision.questionText
                        && ($0.rawFreeText ?? $0.selectedOptionLabel) == (decision.rawFreeText ?? decision.selectedOptionLabel)
                }
        }
        // A changed live answer not captured yet is pending input.
        guard contains(history.versions[active]) else { return .distantFuture }
        var first = active
        while first > 0, contains(history.versions[first - 1]) { first -= 1 }
        // An explicit answer has its own commit time. Reaffirming the same
        // words is new input; copying that answer during source refresh is
        // not. Carried decisions retain their original node identity, so a
        // recorded answer can be recovered across the unchanged run.
        let committed = history.versions[first...active].flatMap { $0.interviewState.answers }
            .filter { $0.nodeID == decision.nodeID && !$0.skipped }
            .map(\.committedAt).max()
        if let committed { return committed }
        return history.versions[first].createdAt
    }
}
