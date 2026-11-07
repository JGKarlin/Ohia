import Foundation
import NaturalLanguage
import OhiaCore

public struct ComposerPipelineStage: Codable, Sendable, Equatable {
    public var role: ComposerModelRole
    public var scope: GenerationPersonalizationScope
    public var promptTokens: Int?
    public var elapsed: TimeInterval
    public var completed: Bool
    public var error: String?
    /// Prompt tokens restored from a saved KV cache instead of prefilled.
    public var reusedPromptTokens: Int? = nil
    public var prefillSeconds: Double? = nil
    public var decodeSeconds: Double? = nil
    public var generatedTokens: Int? = nil

    /// `p2510/r1800 pf3.1 dc8.9 g310`, each part omitted when unknown.
    public var timingSummary: String {
        GenerationDiagnostics.timingSummary(promptTokens: promptTokens, reusedTokens: reusedPromptTokens,
            prefillSeconds: prefillSeconds, decodeSeconds: decodeSeconds, generatedTokens: generatedTokens)
    }
}

public struct ComposerPipelineOutput: Sendable {
    public let body: String
    public let brief: ComposerContentBrief
    public let stages: [ComposerPipelineStage]
    public let personalization: GenerationPersonalization?
    public let diagnostics: GenerationDiagnostics?
    public let check: ComposerDraftCheckRecord
    public var modelCallCount: Int { stages.count }
}

/// What the one semantic check found in the written draft and what the one
/// repair did about it, kept with the generated revision's basis.
public struct ComposerDraftCheckRecord: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// The check found nothing to fix.
        case accepted
        /// The model rephrased or added what the check named; anything
        /// invented was removed.
        case repaired
        /// The sentences the check named were removed; no model call was needed,
        /// or the repair's answer was unusable.
        case deleted
        /// An item the author asked for is still left out: there was no time
        /// for the repair, or its answer was unusable. Nothing invented remains.
        case unrepaired
        /// The check returned no usable answer; only the mechanical checks ran.
        case unchecked
        /// Too little of the action's time was left to check the draft.
        case skipped
    }
    public var outcome: Outcome
    public var findings: [ComposerPublicationFinding]
    public var detail: String?

    public init(outcome: Outcome, findings: [ComposerPublicationFinding] = [], detail: String? = nil) {
        self.outcome = outcome
        self.findings = findings
        self.detail = detail
    }
}

public enum ComposerContentPipeline {
    /// The writer's draws for one request: the author's adapter, a fresh
    /// adapter draw, then base weights. A draw that is cut off, loops,
    /// leaks reasoning or replays the correspondent's mail is not an email,
    /// and an adapter that produced one tends to repeat it (the writer
    /// samples near-greedily), so retries are sampled warmer and, only when
    /// every adapter draw broke down that way, the last drops the adapter.
    /// Measured on a real revision request: the adapter wrote no usable email
    /// in 5 of 12 draws; base weights in 0 of 12.
    static let writerDrawCount = 3
    static let roomExhausted = "The sources this draft keeps leave the drafting model too little room to finish the email. Remove a source you do not need in Sources."

    public static func generate(
        request: ComposerGenerationRequest,
        cachedBrief: ComposerContentBrief? = nil,
        action: ComposerGenerationAction = ComposerGenerationAction(),
        generate: @escaping ComposerModelCall
    ) async throws -> ComposerPipelineOutput {
        try action.check()
        try request.content.validate()
        let recorder = ComposerStageRecorder()
        let call: ComposerModelCall = { prompt, role, maximumTokens in
            try action.check()
            let started = Date()
            do {
                let result = try await generate(prompt, role, maximumTokens)
                try action.check()
                await recorder.append(ComposerPipelineStage(role: role, scope: role.scope,
                    promptTokens: result.diagnostics?.promptTokenCount, elapsed: Date().timeIntervalSince(started),
                    completed: result.completed, error: nil,
                    reusedPromptTokens: result.diagnostics?.reusedPromptTokenCount,
                    prefillSeconds: result.diagnostics?.promptSeconds,
                    decodeSeconds: result.diagnostics?.decodeSeconds,
                    generatedTokens: result.diagnostics?.generatedTokenCount))
                return result
            } catch {
                await recorder.append(ComposerPipelineStage(role: role, scope: role.scope,
                    promptTokens: nil, elapsed: Date().timeIntervalSince(started), completed: false,
                    error: String(describing: error)))
                throw error
            }
        }
        // Evidence indexing and instruction coverage are application work.
        // The writer receives the original authority, never a model-created
        // interpretation that requires another inference before every draft.
        let brief: ComposerContentBrief
        if let cachedBrief, let completed = try? cachedBrief.completingCoverage(for: request.content),
           (try? completed.validate(against: request.content)) != nil {
            brief = completed
        } else {
            brief = try ComposerContentBrief.prepared(from: request.content)
        }
        // What an earlier answer the author kept asked of them, and their
        // email shows done, is owed no more: read once, before any draw.
        var request = request
        if request.doneEarlierRequests == nil, action.remainingSeconds >= minimumSecondsForCheck {
            do {
                request.doneEarlierRequests = try await ComposerDraftRepair.doneEarlierRequests(request: request,
                    brief: brief, generate: call)
            } catch {
                try rethrowingUserCancellation(error, action: action)
            }
        }
        let writerPrompt = try ComposerWriterPrompt.render(request: request, brief: brief)
        // Engine, window and cancellation failures end the action at once;
        // only an unusable draw is drawn again.
        var rejections: [String] = []
        var leftOut: [String] = []
        var leftOutIDs: [String] = []
        // Every draw is in the author's voice: the first as their adapter
        // writes, each retry sampled differently. Only when every draw on
        // their adapter broke down (copied their email, looped, stopped
        // short) is the last one on base weights.
        var broke = true
        // A draw turned down for what it said (their email handed back, or
        // nothing of the author's left) is followed by one told why: the
        // same prompt, sampled again, writes the same draft.
        var turnedDown: ComposerWriterPrompt.Rejection?
        var firstDraft: String?
        var attempt = -1
        while attempt + 1 < writerDrawCount {
            attempt += 1
            let last = attempt == writerDrawCount - 1
            let role: ComposerModelRole = attempt == 0 ? .writer : (last && broke ? .baseWriter : .writerRetry)
            let started = Date()
            let output: ComposerModelOutput
            // Whether this draw is told why the last was turned down: the
            // note takes room the fitted prompt left the email.
            var noted = turnedDown != nil
            do {
                do {
                    output = try await call(turnedDown.map { ComposerWriterPrompt.retrying(writerPrompt, after: $0, request: request) }
                        ?? writerPrompt, role, ComposerWriterWindow.outputReserve)
                } catch ComposerContentError.budgetExceeded where noted {
                    // A prompt fitted to the window's edge has no room for the
                    // note: drawn again as fitted, sampled as this draw is.
                    noted = false
                    output = try await call(writerPrompt, role, ComposerWriterWindow.outputReserve)
                }
            } catch ComposerContentError.deadlineExceeded where !leftOut.isEmpty {
                // Out of time after an answer was left out: say which.
                break
            }
            do {
                // The last draw is not failed for its language: a short reply
                // around an English signature can read as English.
                // A revision with no new instruction keeps the author's
                // greeting and sign-off, and a rewrite for a Length move must
                // go the way it was moved, written and after the check.
                // A retry on the adapter is sampled warmer: it is held to the
                // language even last.
                let written = try candidate(output, request: request, enforceLanguage: !last || role == .writerRetry)
                // A reply that greets its own author was written from the
                // correspondent's side: drawn again, as a copy of theirs is.
                if request.content.mode == .reply, Self.greetsAuthor(written, request: request) {
                    throw ComposerContentError.incomplete(greetedAuthor)
                }
                // A redraw that leaves out the greeting or sign-off keeps the
                // ones the author's adapter wrote first, their own: never from
                // a draw that copied the correspondent or greets the author,
                // and never around a draw in another language.
                if attempt == 0, !Self.greetsAuthor(written, request: request) { firstDraft = written }
                let framed = attempt > 0 && firstDraft != nil
                    && wrongLanguage(written, requested: request.content.languageID) == nil
                let body = Self.isRewriteOnly(request) && request.currentBody != nil
                    ? ComposerBoilerplate.replacingFrame(written, of: request.currentBody ?? "")
                    : framed ? ComposerBoilerplate.keepingFrame(written, of: firstDraft ?? "") : written
                try Self.followsLength(body, request: request)
                try action.check()
                let checked = try await checked(body: body, request: request, brief: brief, action: action, call: call,
                    required: Set(leftOutIDs),
                    readingEverySentence: rejections.contains { [Self.nothingAuthorized, Self.nothingNew].contains($0) },
                    onBaseWeights: role == .baseWriter)
                // After a draft left an answer out, or said nothing of the
                // author's, a draft the check did not read is never the one
                // sent: nothing says it has the answer, or anything of theirs.
                if checked.record.outcome == .skipped || checked.record.outcome == .unchecked {
                    if !leftOut.isEmpty { throw AnswersLeftOut(ids: leftOutIDs, answers: leftOut) }
                    if let unsaid = rejections.first(where: { [Self.nothingAuthorized, Self.nothingNew].contains($0) }) {
                        throw ComposerContentError.rejected(unsaid)
                    }
                }
                try Self.followsLength(checked.body, request: request)
                return ComposerPipelineOutput(body: checked.body, brief: brief, stages: await recorder.stages,
                    personalization: output.personalization, diagnostics: output.diagnostics, check: checked.record)
            } catch let error as ComposerContentError where !leftOut.isEmpty && Self.endsWithAnswerLeftOut(error) {
                // Nothing usable, or no time, after an answer was left out:
                // the author is told which answer.
                break
            } catch ComposerContentError.rejected(let reason)
                where [Self.nothingAuthorized, Self.nothingNew].contains(reason) && leftOut.isEmpty
                    && attempt + 1 < writerDrawCount
                    && action.remainingSeconds >= Date().timeIntervalSince(started) + minimumSecondsForCheck {
                // Nothing of the author's was left once what they never said
                // went: another draw, told so, may say only what they gave.
                // The author is asked only when every draw ends that way.
                if !rejections.contains(reason) { rejections.append(reason) }
                turnedDown = reason == Self.nothingNew ? .repeated : .unauthorized
                broke = false
            } catch ComposerContentError.rejected(let reason)
                where [Self.nothingAuthorized, Self.nothingNew].contains(reason) && leftOut.isEmpty
                    && Self.lengthMove(request) != nil {
                // A Length move whose last draw had nothing more of the
                // author's to say leaves the draft as it was.
                throw ComposerContentError.incomplete((Self.lengthMove(request) ?? 1) > 0 ? Self.noLongerToSay : Self.noShorterToSay)
            } catch let error where Self.drawsAgain(error) {
                // A draft that cannot carry an answer of the author's as they
                // gave it is not sent: another draw may.
                let reason: String
                if let missing = error as? AnswersLeftOut {
                    for answer in missing.answers where !leftOut.contains(answer) { leftOut.append(answer) }
                    for id in missing.ids where !leftOutIDs.contains(id) { leftOutIDs.append(id) }
                    reason = missing.reason
                } else if case ComposerContentError.incomplete(let text) = error {
                    reason = text
                } else {
                    throw error
                }
                if !rejections.contains(reason) { rejections.append(reason) }
                if reason == Self.copiedCorrespondent {
                    turnedDown = .copied
                    if attempt == 0 { firstDraft = nil }
                } else if reason == Self.greetedAuthor {
                    turnedDown = .greetedAuthor
                }
                // What the draft said, not the adapter breaking down, is no
                // reason to leave the author's voice.
                if error is AnswersLeftOut || Self.lengthRejections.contains(reason) { broke = false }
                // Another draw after an answer was left out needs the time
                // this one took, and the check's: without it, the author is
                // told which answer now rather than the action running out.
                if !leftOut.isEmpty, action.remainingSeconds < Date().timeIntervalSince(started) + minimumSecondsForCheck {
                    break
                }
                try action.check()
                // Cut off short of the full allowance: the prompt left the
                // writer less room than an email needs, and every draw has
                // the same room. A draw told why the last was turned down
                // had the note's room less: the next is drawn as fitted, and
                // only its cut says the sources leave too little.
                if !output.completed, let generated = output.diagnostics?.generatedTokenCount,
                   generated < ComposerWriterWindow.outputReserve {
                    guard noted else { throw ComposerContentError.incomplete(roomExhausted) }
                    turnedDown = nil
                }
                // Another adapter draw may run as long as this one did; when
                // the action's time cannot also cover the base draw after a
                // breakdown, go straight to the base draw.
                let elapsed = await recorder.stages.last?.elapsed ?? 0
                if broke, attempt + 2 < writerDrawCount, action.remainingSeconds < 2 * elapsed {
                    attempt = writerDrawCount - 2
                }
            }
        }
        // No draw could say an answer of the author's as they gave it: they
        // are told which, and asked to put it in their own words.
        if !leftOut.isEmpty { throw ComposerContentError.rejected(Self.answersNotWritten(leftOut)) }
        // A Length move no draw could make leaves the draft as it was,
        // whatever turned the draws down (nothing more of the author's to
        // say, a copy of their email): the author is told it is unchanged.
        if let move = Self.lengthMove(request), !rejections.isEmpty, rejections.allSatisfy({
            Self.lengthRejections.contains($0) || [Self.nothingAuthorized, Self.nothingNew, Self.copiedCorrespondent].contains($0)
        }) {
            throw ComposerContentError.incomplete(move > 0 ? Self.noLongerToSay : Self.noShorterToSay)
        }
        // A draw left nothing of the author's to say: they are asked.
        if let unsaid = rejections.first(where: { [Self.nothingAuthorized, Self.nothingNew].contains($0) }) {
            throw ComposerContentError.rejected(unsaid)
        }

        // A Length move with nothing more, or less, to say is not a failure
        // of the draft: it stays, and the author is told why.
        if !rejections.isEmpty, rejections.allSatisfy(Self.lengthRejections.contains) {
            throw ComposerContentError.incomplete(rejections.first == Self.lengthRejections[0] ? Self.noLongerToSay : Self.noShorterToSay)
        }
        throw ComposerContentError.incomplete(
            "None of \(writerDrawCount) drafting attempts produced a usable email. "
                + rejections.joined(separator: " "))
    }

    /// The author's answers a checked draft could not carry as they gave them.
    struct AnswersLeftOut: Error {
        static let drawReason = "A draft left out an answer of yours it could not write as you gave it."
        /// The checklist items, and the author's answers as they gave them.
        let ids: [String]
        let answers: [String]
        var reason: String { Self.drawReason }
        init(_ items: [ComposerDraftRepair.Missing]) {
            ids = items.map(\.id)
            answers = items.map { ComposerPublicationAudit.authorsWords($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        init(ids: [String], answers: [String]) { self.ids = ids; self.answers = answers }
    }

    /// Errors after which, once an answer was left out, the author is told
    /// which answer rather than this error.
    static func endsWithAnswerLeftOut(_ error: ComposerContentError) -> Bool {
        // After drafts in their voice could not carry an answer, the author
        // is told which, rather than drafting on with no answer to give.
        switch error {
        case .rejected, .deadlineExceeded: true
        default: false
        }
    }

    static func drawsAgain(_ error: Error) -> Bool {
        if error is AnswersLeftOut { return true }
        if case ComposerContentError.incomplete = error { return true }
        return false
    }

    static func answersNotWritten(_ answers: [String]) -> String {
        let quoted = answers.map { "“\($0)”" }.joined(separator: ", ")
        return (answers.count == 1 ? "Your answer \(quoted) could not be written into the draft as you gave it"
            : "Your answers \(quoted) could not be written into the draft as you gave them")
            + ", so no draft was made. Add \(answers.count == 1 ? "it" : "them") in your own words, or draft again."
    }

    /// A rewrite asked for a longer Length that is no longer than the draft,
    /// or for a shorter one that is no shorter, did not do what was asked:
    /// another draw is taken, and the draft stays as it was if none does.
    static let lengthRejections = ["A longer Length came back no longer than the draft.",
                                   "A shorter Length came back no shorter than the draft."]
    static let noLongerToSay = "The draft is unchanged: a longer version said nothing more that your answers and the sources support."
    static let noShorterToSay = "The draft is unchanged: a shorter version could not say what it must in fewer words."

    /// A pass that only rewrites what the draft says: no instruction typed
    /// for it and no change the author made by hand since the draft was
    /// written. Only then is the draft's own frame and length the measure.
    static func isRewriteOnly(_ request: ComposerGenerationRequest) -> Bool {
        !request.content.requirements.contains { $0.id == ComposerGenerationRequestCompiler.pendingInstructionID }
    }

    /// Whether a draft's greeting names the author and not the person it
    /// answers ("Dear Professor Morgan," on Morgan's own reply): a draw that
    /// wrote from the correspondent's side.
    static func greetsAuthor(_ draft: String, request: ComposerGenerationRequest) -> Bool {
        guard let first = draft.components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              ComposerBoilerplate.isGreeting(first) else { return false }
        // A greeting the author wrote, in the draft or by hand, is theirs.
        let greeting = first.trimmingCharacters(in: .whitespaces)
        func opening(_ text: String) -> String? {
            text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        if request.currentBody.flatMap(opening) == greeting
            || request.content.manualEdits.contains(where: { opening($0.replacement) == greeting }) { return false }
        // Name particles ("van", "Le", "de") name no one.
        let particles: Set<String> = ["van", "von", "der", "den", "de", "del", "della", "di", "da", "du", "des", "le", "la", "dos", "das", "ter", "ten", "bin", "al", "el"]
        func words(_ text: String) -> [String] { text.lowercased().split { !$0.isLetter }.map(String.init) }
        func tokens(_ name: String?) -> Set<String> {
            Set(words(name ?? "")).filter { $0.count >= 2 && !particles.contains($0) }
        }
        func latin(_ token: String) -> Bool { token.unicodeScalars.allSatisfy { $0.isASCII } }
        // In a script written without spaces, a name is in the name that
        // holds it: 佐藤 in 佐藤花子.
        func same(_ one: String, _ other: String) -> Bool {
            one == other || (!latin(one) && !latin(other) && (one.contains(other) || other.contains(one)))
        }
        // The person answered is known only by a display name: not their
        // address (initials, a role, anything), and not where an initial of
        // theirs could be the name the greeting gives ("A. Lee" may be an Alex).
        guard let display = request.content.anchor?.authorDisplayName, !display.contains("@") else { return false }
        let names = Set(ComposerBoilerplate.greetingName(first)).filter { !particles.contains($0) }
        let recipient = tokens(display)
        let author = names.filter { name in tokens(request.content.authorDisplayName).contains { same(name, $0) } }
        let initials = Set(words(display).filter { $0.count == 1 && latin($0) })
        guard !author.contains(where: { $0.first.map { initials.contains(String($0)) } == true }) else { return false }
        // Only where the person answered could be told apart: their name
        // known in the greeting's script, and not the one it gives.
        guard !author.isEmpty, recipient.contains(where: { token in author.contains { latin($0) == latin(token) } }),
              !names.contains(where: { name in recipient.contains { same(name, $0) } }) else { return false }
        // Nor where their email signs, under its sign-off, with the author's
        // name the greeting gives ("Best, Alex" from "Graduate Office").
        // Thanking the author by name ("Thanks so much, Alex!") or a title
        // in a signature ("Assistant Professor") signs nothing.
        guard let anchor = request.content.anchor else { return true }
        let lines = QuotedHistoryTail.latestAuthoredText(from: otherPartyText(anchor.exactText)).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Everything under the sign-off, or with none the last lines, may
        // carry the name ("Alex", "-- Alex", "alex", "Alex (he/him)",
        // above "Sent from my iPhone"): a line of a few words with no
        // sentence in it.
        let signature = lines.dropFirst().lastIndex(where: ComposerBoilerplate.isSignOff)
            .map { lines[($0 + 1)...] } ?? lines.dropFirst().suffix(3)
        let signed = signature.contains { raw in
            let line = raw.replacingOccurrences(of: #"^[-–—\s]+|\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let lineWords = words(line)
            // A name line only: not thanks or a meeting by name ("Thanks,
            // Alex", "See you soon Alex"), a copy, an address, someone's
            // assistant, or a name with an honorific ("モーガン先生のゼミ生").
            let nameLike = ComposerBoilerplate.isNameLine(line) || ComposerBoilerplate.isUnspacedName(line)
                || (lineWords.count <= 3 && line.allSatisfy { $0.isLetter || $0 == " " || $0 == "." || $0 == "-" || $0 == "'" })
            return nameLike && lineWords.count <= 4 && !line.contains(where: { ",，、!?！？:：<>@".contains($0) })
                && !ComposerBoilerplate.isSignOff(line)
                && Set(lineWords).isDisjoint(with: ["thanks", "thank", "thx", "cheers", "see", "cc", "to", "for", "of",
                                                    "assistant", "secretary", "behalf", "dear", "hi", "hello"])
                && !["先生", "様", "さん", "殿", "老师", "老師", "님"].contains(where: line.contains)
                && tokens(line).contains { token in author.contains { same($0, token) } }
        }
        return !signed
    }

    /// The way a rewrite was asked to move Length (+1 longer, -1 shorter),
    /// or nil when it is not a Length move of the displayed draft.
    static func lengthMove(_ request: ComposerGenerationRequest) -> Int? {
        guard let previous = request.presentation.previousLengthPoint, let now = request.presentation.lengthPoint,
              previous != now, request.currentBody != nil, isRewriteOnly(request),
              request.content.manualEdits.allSatisfy({ $0.baseRevisionID != request.displayedRevisionID }) else { return nil }
        return now > previous ? 1 : -1
    }

    static func followsLength(_ body: String, request: ComposerGenerationRequest) throws {
        guard let previous = request.presentation.previousLengthPoint, let now = request.presentation.lengthPoint,
              previous != now, let current = request.currentBody, isRewriteOnly(request),
              request.content.manualEdits.allSatisfy({ $0.baseRevisionID != request.displayedRevisionID }) else { return }
        func size(_ text: String) -> Int {
            ComposerDraftEvidence.restatementTokens(ComposerBoilerplate.strip(text, readingNames: true)).count
        }
        let before = size(current), after = size(body)
        if now > previous, after <= before { throw ComposerContentError.incomplete(lengthRejections[0]) }
        if now < previous, after >= before { throw ComposerContentError.incomplete(lengthRejections[1]) }
    }

    /// Time the check needs to be worth starting, and the repair after it:
    /// a check that cannot finish would cost the draft itself.
    static let minimumSecondsForCheck: TimeInterval = 20
    static let minimumSecondsForRepair: TimeInterval = 10
    /// The time the narrow read beside an open request takes, beyond what
    /// the repair after it needs.
    static let minimumSecondsForOpenRead: TimeInterval = 5

    /// The one semantic check, and at most one repair of what it finds. The
    /// repair edits only the sentences the check names; when its answer is
    /// unusable, those sentences are removed instead, which cannot add
    /// anything. A check that returns no usable answer leaves the draft as
    /// the mechanical checks passed it. Deadline and cancellation end the
    /// action as everywhere else.
    static func checked(body: String, request: ComposerGenerationRequest, brief: ComposerContentBrief,
                        action: ComposerGenerationAction, call: ComposerModelCall,
                        required: Set<String> = [],
                        readingEverySentence: Bool = false,
                        onBaseWeights: Bool = false) async throws -> (body: String, record: ComposerDraftCheckRecord) {
        let body = (try? usableBody(ComposerDraftRepair.restoringManualEdits(body, request: request),
            request: request)) ?? body
        guard action.remainingSeconds >= minimumSecondsForCheck else { return (body, .init(outcome: .skipped)) }
        var audit: ComposerPublicationAudit
        do {
            audit = try await ComposerPublicationAudit.review(body: body, request: request, brief: brief, generate: call)
        } catch {
            // The author cancelling ends the action. A check that fails, or
            // that the action's time runs out on, leaves the written draft.
            try rethrowingUserCancellation(error, action: action)
            return (body, .init(outcome: .unchecked, detail: (error as? LocalizedError)?.errorDescription
                ?? String(describing: type(of: error))))
        }
        try rethrowingUserCancellation(nil, action: action)
        // After a draw said nothing of the author's, a sentence this check
        // did not read is not shown to be theirs: the draft counts as unread.
        let unreadSentences = audit.unread.filter { $0.hasPrefix("C") }
        if readingEverySentence, !unreadSentences.isEmpty {
            return (body, .init(outcome: .unchecked, detail: "The check did not read \(unreadSentences.joined(separator: ", "))."))
        }
        // An answer an earlier draft left out, which this check did not read,
        // is not shown to be here: this draft is not sent either.
        let unread = required.intersection(audit.unread + audit.unresolved)
        if !unread.isEmpty {
            let items = ComposerPublicationAudit.checklist(request: request, brief: brief).filter { unread.contains($0.id) }
            throw AnswersLeftOut(items.map { ComposerDraftRepair.Missing(id: $0.id, text: $0.text) })
        }
        let detail = [
            audit.unresolved.isEmpty ? nil
                : "The check did not say whether a later decision replaced \(audit.unresolved.joined(separator: ", ")); neither required nor forbidden.",
            audit.unread.isEmpty ? nil
                : "The check did not read \(audit.unread.joined(separator: ", ")).",
        ].compactMap { $0 }.joined(separator: " ")
        // A sentence the check passed beside a request the author left open
        // may still answer it: a bare yes ("はい、承知しました。", "No
        // problem."), "I'm not sure I'll meet them", or a yes joined to an
        // answer of theirs ("Yes, let's meet, and I'll send the feedback").
        // One call reads those, in any language; one that answers goes, and
        // an answer of the author's it carried is added back by the repair.
        // What they typed is theirs; a question, by its words and by the
        // check's reading, says no yes (one the author did not ask is the
        // check's finding already). Not read (one more try), that is said.
        var openRead: String?
        if !ComposerPublicationAudit.undecided(request: request).isEmpty, audit.nothingLeft != true {
            let passages = ComposerPublicationAudit.sentences(of: body).sentences
            let flagged = Set(audit.findings.compactMap(\.sentenceID))
            let kinds = Dictionary(audit.sentences.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
            let typed = ComposerDraftRepair.authorSentences(request).kept.map { ComposerDraftRepair.normalized($0).lowercased() }
            let salutation = passages.first.flatMap { ComposerBoilerplate.isGreeting($0.text) ? $0.id : nil }
            let itemIDs = Set(audit.checklist.map(\.id))
            let carrying = Set(audit.checklist.compactMap(\.sentenceID))
                .union(audit.sentences.filter { !itemIDs.isDisjoint(with: $0.references) }.map(\.id))
            // Never the second line of a salutation that is only its word
            // ("你好！"; "您好，没问题。" says yes).
            let statements = passages.enumerated().filter { index, passage in
                let plain = ComposerDraftRepair.normalized(passage.text).lowercased()
                let asks = ComposerDraftEvidence.isQuestion(passage.text) && kinds[passage.id] == .question
                let bare = passage.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                return kinds[passage.id] != nil && !flagged.contains(passage.id) && passage.id != salutation && !asks
                    && !typed.contains { $0.contains(plain) }
                    && !(index == 1 && salutation != nil && ComposerBoilerplate.isSalutation(passage.text)
                        && !bare.contains(where: { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == "、" }))
            }.map { (id: $0.element.id, text: $0.element.text) }
            if !statements.isEmpty {
                // Read again, only what is still unread, when the read could
                // not be read or left a sentence out; the two together stand
                // (what either found answering, answering).
                var read: ComposerDraftRepair.OpenRequestReading?
                var asked = statements
                for _ in 0..<2 where !asked.isEmpty
                    && action.remainingSeconds >= minimumSecondsForRepair + minimumSecondsForOpenRead {
                    let next: ComposerDraftRepair.OpenRequestReading?
                    do {
                        next = try await ComposerDraftRepair.answeringOpenRequests(asked, among: statements,
                            request: request, generate: call)
                    } catch {
                        try rethrowingUserCancellation(error, action: action)
                        break
                    }
                    if let next {
                        let answering = (read?.answering ?? [:]).merging(next.answering) { first, _ in first }
                        read = ComposerDraftRepair.OpenRequestReading(answering: answering,
                            unread: next.unread.filter { answering[$0] == nil })
                    }
                    let unread = read.map { Set($0.unread) } ?? Set(asked.map(\.id))
                    asked = asked.filter { unread.contains($0.id) }
                }
                // Sentences never read stay unread.
                if let found = read {
                    let reached = Set(statements.map(\.id)).subtracting(asked.map(\.id))
                    read = ComposerDraftRepair.OpenRequestReading(answering: found.answering,
                        unread: statements.map(\.id).filter { !reached.contains($0) && found.answering[$0] == nil })
                }
                var going = flagged
                if let read {
                    let items = ComposerPublicationAudit.checklist(request: request, brief: brief)
                    for sentence in statements where read.answering[sentence.id] != nil {
                        going.insert(sentence.id)
                        audit.findings.append(ComposerPublicationFinding(kind: .undecided,
                            requirementIDs: [read.answering[sentence.id] ?? ""], candidateQuote: sentence.text,
                            explanation: "This answers a request the author has not answered: “\(sentence.text)”",
                            sentenceID: sentence.id))
                    }
                    // An answer of theirs only a sentence that went expressed
                    // is left out now: the repair adds it back. What still
                    // expresses it is a statement (a question about it, or a
                    // courtesy, does not), as the check counts it.
                    let kept = audit.sentences.filter { !going.contains($0.id) }
                    let texts = Dictionary(passages.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
                    // An answer whose own sentence goes is carried by a kept
                    // statement only where the answer check reads that
                    // statement saying it, the same way round ("by Monday" is
                    // not "by Friday"; "I'm not free Monday, but I can make it
                    // on Tuesday" is not "No, I can't make it on Tuesday"). Only
                    // a statement holding every word of it is asked about. Not
                    // read, it is added back.
                    func words(_ text: String) -> Set<String> {
                        ComposerDraftEvidence.contentTokens(text.filter { !"、，「」『』・".contains($0) })
                    }
                    var asked: [(item: ComposerDraftRepair.Missing, sentence: String, sentenceID: String)] = []
                    for entry in audit.checklist {
                        guard entry.sentenceID.map({ read.answering[$0] != nil }) ?? false,
                              let item = items.first(where: { $0.id == entry.id }) else { continue }
                        let needed = words(ComposerPublicationAudit.authorsWords(item.text))
                        guard !needed.isEmpty, let whole = kept.first(where: { sentence in
                            [.position, .refusal, .fact].contains(sentence.kind) && sentence.references.contains(entry.id)
                                && texts[sentence.id].map { needed.isSubset(of: words($0)) } == true
                        }), let text = texts[whole.id] else { continue }
                        asked.append((ComposerDraftRepair.Missing(id: entry.id, text: item.text), text, whole.id))
                    }
                    var carriedIn: [String: String] = [:]
                    if !asked.isEmpty, action.remainingSeconds >= minimumSecondsForRepair + minimumSecondsForOpenRead {
                        do {
                            let says = try await ComposerDraftRepair.confirmedAnswers(asked.map { ($0.item, $0.sentence) },
                                request: request, generate: call)
                            for entry in asked where says.contains(entry.item.id) { carriedIn[entry.item.id] = entry.sentenceID }
                        } catch {
                            try rethrowingUserCancellation(error, action: action)
                        }
                    }
                    for index in audit.checklist.indices {
                        let id = audit.checklist[index].id
                        let item = items.first { $0.id == id }
                        let carriedBy = Set([audit.checklist[index].sentenceID].compactMap { $0 })
                            .union(audit.sentences.filter { $0.references.contains(id) }.map(\.id))
                        let stating = kept.filter { [.position, .refusal, .fact].contains($0.kind) && $0.references.contains(id) }
                        guard !carriedBy.isEmpty, !carriedBy.isDisjoint(with: Set(read.answering.keys)) else { continue }
                        // Its own sentence gone, it is added back unless the
                        // answer check read a kept statement saying it; that
                        // statement then carries it.
                        if audit.checklist[index].sentenceID.map({ read.answering[$0] != nil }) ?? false {
                            if let whole = carriedIn[id] {
                                audit.checklist[index].sentenceID = whole
                                continue
                            }
                        } else if !stating.isEmpty || kept.contains(where: { audit.checklist[index].sentenceID == $0.id }) {
                            continue
                        }
                        let requirement = item?.requirementID ?? id
                        audit.checklist[index].sentenceID = nil
                        guard !audit.findings.contains(where: { $0.sentenceID == nil && $0.requirementIDs.contains(requirement) })
                        else { continue }
                        audit.findings.append(ComposerPublicationFinding(kind: id.hasPrefix("M") ? .manualEdit : .omission,
                            requirementIDs: [requirement], candidateQuote: nil,
                            explanation: "The draft does not express: “\(item?.text ?? id)”"))
                    }
                }
                // What the read could not reach (unreadable, or a sentence
                // left out of it) is said. After a draw with nothing of the
                // author's, it goes too, unless it carries an answer of theirs
                // or the draft would be left with nothing to send; the draft is
                // never lost for it, and stays as written otherwise.
                let unreadIDs = Set(read?.unread ?? statements.map(\.id))
                if !unreadIDs.isEmpty {
                    let unread = statements.filter { unreadIDs.contains($0.id) }
                    // A closing ("祝好，", "Viele Grüße,") is never taken
                    // out for going unread: the name under it would be left.
                    let removable = unread.filter { !carrying.contains($0.id) && !ComposerBoilerplate.isSignOff($0.text) }
                    if readingEverySentence, !removable.isEmpty, let open = ComposerPublicationAudit.undecided(request: request).first {
                        let removals = removable.map { sentence in
                            ComposerPublicationFinding(kind: .undecided, requirementIDs: [open.id], candidateQuote: sentence.text,
                                explanation: "The check could not read whether this answers a request the author left open: “\(sentence.text)”",
                                sentenceID: sentence.id)
                        }
                        var trial = audit
                        trial.findings += removals
                        // Something besides the greeting must be left: a name
                        // alone under it ("Hi Sam,\nAuthor") is not an email.
                        if let left = ComposerDraftRepair.deletingFlagged(body: body, audit: trial), hasContent(left, author: request.content.authorDisplayName, signedAs: Self.signedNames(request)),
                           ComposerPublicationAudit.sentences(of: left).sentences.contains(where: { !ComposerBoilerplate.isGreeting($0.text) }),
                           (try? usableBody(left, request: request)) != nil {
                            audit.findings += removals
                        }
                    }
                    openRead = "The check did not read whether \(unread.map(\.id).joined(separator: ", ")) answer a request you left open."
                }
            }
        }
        // A draft on base weights is not the author's voice, and what it says
        // as courtesy may say more of theirs ("…心よりお詫び申し上げます" read as
        // a pleasantry): read again, a sentence that does goes unless an answer
        // or instruction of theirs carries it. Not read, it stays.
        if onBaseWeights, audit.nothingLeft != true,
           action.remainingSeconds >= minimumSecondsForRepair + minimumSecondsForOpenRead {
            let flagged = Set(audit.findings.compactMap(\.sentenceID))
            let passages = ComposerPublicationAudit.sentences(of: body).sentences
            let salutation = passages.first.flatMap { ComposerBoilerplate.isGreeting($0.text) ? $0.id : nil }
            // What carries an answer, an instruction or an edit of theirs, as
            // the checklist maps it or a sentence cites it, and what they
            // typed, is theirs: never read for more.
            let itemIDs = Set(audit.checklist.map(\.id))
            let carrying = Set(audit.checklist.compactMap(\.sentenceID))
                .union(audit.sentences.filter { !itemIDs.isDisjoint(with: $0.references) }.map(\.id))
            let typed = ComposerDraftRepair.authorSentences(request).kept.map { ComposerDraftRepair.normalized($0).lowercased() }
            let courtesies = Set(audit.sentences.filter { $0.kind == .courtesy }.map(\.id))
            let asked = passages.filter { passage in
                let plain = ComposerDraftRepair.normalized(passage.text).lowercased()
                return courtesies.contains(passage.id) && !flagged.contains(passage.id) && passage.id != salutation
                    && !carrying.contains(passage.id) && !typed.contains { $0.contains(plain) }
                    && passage.text.contains(where: \.isLetter)
            }.map { (id: $0.id, text: $0.text) }
            do {
                if let more = try await ComposerDraftRepair.sayingMoreThanCourtesy(asked, request: request, generate: call) {
                    for sentence in asked where more.contains(sentence.id) {
                        audit.findings.append(ComposerPublicationFinding(kind: .unauthorizedPosition, requirementIDs: [],
                            candidateQuote: sentence.text,
                            explanation: "This says something of the author's they did not give: “\(sentence.text)”",
                            sentenceID: sentence.id))
                    }
                }
            } catch {
                try rethrowingUserCancellation(error, action: action)
            }
        }
        let noted = [detail.isEmpty ? nil : detail, openRead].compactMap { $0 }.joined(separator: " ")
        let checkedDetail: String? = noted.isEmpty ? nil : noted
        guard !audit.findings.isEmpty else { return (body, .init(outcome: .accepted, detail: checkedDetail)) }
        // Nothing of the author's to say once what they never said goes:
        // they are asked, never sent thanks alone in place of their answer.
        // Removal is the repair unless something must be rephrased or added.
        let (_, sentences) = ComposerPublicationAudit.sentences(of: body)
        if audit.nothingLeft == true { throw nothingOfTheAuthors(audit, sentences: sentences, request: request) }
        let rephrase = !ComposerDraftRepair.flags(audit.findings, sentences: sentences,
            kinds: ComposerDraftRepair.rewrittenKinds).isEmpty
        let add = !ComposerDraftRepair.missing(audit.findings,
            checklist: ComposerPublicationAudit.checklist(request: request, brief: brief), audit: audit).isEmpty
        if rephrase || add, action.remainingSeconds >= minimumSecondsForRepair {
            let repaired: ComposerDraftRepair.Repaired?
            do {
                repaired = try await ComposerDraftRepair.repair(body: body, audit: audit, request: request,
                    brief: brief, generate: call)
            } catch {
                // Removing the named sentences needs no model and no time.
                try rethrowingUserCancellation(error, action: action)
                repaired = nil
            }
            try rethrowingUserCancellation(nil, action: action)
            // The repair writes sentences anew: the author's changes are put
            // back in what it wrote, as in what the writer wrote.
            if let repaired {
                guard repaired.unexpressed.isEmpty else { throw AnswersLeftOut(repaired.unexpressed) }
                let restored = ComposerDraftRepair.restoringManualEdits(repaired.body, request: request)
                if hasContent(restored, author: request.content.authorDisplayName, signedAs: Self.signedNames(request)), let usable = try? usableBody(restored, request: request) {
                    return (usable, .init(outcome: .repaired, findings: audit.findings, detail: checkedDetail))
                }
            }
        }
        // What the author typed after No, if the draft left it out, needs no
        // model either. Any other answer of theirs left out needs the repair:
        // without it, this draft is not sent.
        let restored = ComposerDraftRepair.restoredAuthorsWords(body: body, audit: audit, request: request, brief: brief,
            removed: Set(ComposerDraftRepair.flags(audit.findings, sentences: sentences).map(\.id)))
        let checklist = ComposerPublicationAudit.checklist(request: request, brief: brief)
        let unwritten = ComposerDraftRepair.unwrittenItems(ComposerDraftRepair.missing(audit.findings, checklist: checklist,
            audit: audit), written: restored.items, checklist: checklist, request: request)
        guard unwritten.isEmpty else { throw AnswersLeftOut(unwritten) }
        if let deleted = ComposerDraftRepair.deletingFlagged(body: body, audit: audit, additions: restored.additions) {
            // Nothing in the draft was the author's to say: a greeting and a
            // sign-off around what was removed is not an email.
            guard hasContent(deleted, author: request.content.authorDisplayName, signedAs: Self.signedNames(request)), let usable = try? usableBody(deleted, request: request) else {
                // Everything it said, the author already told these people.
                throw nothingOfTheAuthors(audit, sentences: sentences, request: request)
            }
            return (usable, .init(outcome: .deleted, findings: audit.findings, detail: checkedDetail))
        }
        // Findings that name no sentence (an item left out) and no repair.
        return (body, .init(outcome: .unrepaired, findings: audit.findings, detail: checkedDetail))
    }

    /// Why nothing of the author's is left once the check's findings go:
    /// everything removed was the correspondent's own sentences handed back
    /// (a copy, however the check named it: drawn again, ending on base
    /// weights like any breakdown), only what the author already told them,
    /// or something they never decided (both of which they are asked about).
    static func nothingOfTheAuthors(_ audit: ComposerPublicationAudit, sentences: [ComposerTextPassage],
                                    request: ComposerGenerationRequest) -> ComposerContentError {
        let flagged = audit.findings.filter { $0.sentenceID != nil }
        let ids = Set(flagged.compactMap(\.sentenceID))
        let removed = sentences.filter { ids.contains($0.id) }
        let theirs = ComposerDraftEvidence.otherPartyTexts(request.content)
        let authored = ComposerDraftEvidence.authoredTexts(request.content)
        if !removed.isEmpty, removed.allSatisfy({
            ComposerDraftEvidence.copiedSpeaker($0.text, theirs: theirs, authored: authored) != nil
        }) {
            return .incomplete(copiedCorrespondent)
        }
        return .rejected(Set(flagged.map(\.kind)) == [.repetition] ? nothingNew : nothingAuthorized)
    }

    /// Rethrows only a cancellation the author asked for: the task was
    /// cancelled, or the action's token was before its deadline passed.
    static func rethrowingUserCancellation(_ error: Error?, action: ComposerGenerationAction) throws {
        if let error = error as? CancellationError { throw error }
        if Task.isCancelled || (action.cancellation.isCancelled && Date() < action.deadline) {
            throw CancellationError()
        }
    }

    static let nothingAuthorized = "Every sentence of this draft decided, stated or asked something you have not. Answer its questions or add an instruction, then draft again."
    static let nothingNew = "Every sentence of this draft repeated what you already told them in an earlier email. Answer its questions or add an instruction, then draft again."

    /// The first half of a closing on two lines, however far apart.
    static let closingOpeners: Set<String> = ["此致", "顺颂", "順頌", "顺祝", "順祝", "顺颂商祺"]

    /// Whether anything is left between the salutation and the sign-off.
    /// The names the author signed their earlier email in the thread with.
    static func signedNames(_ request: ComposerGenerationRequest) -> Set<String> {
        ComposerBoilerplate.signatureNames(request.content.evidence.filter { $0.role == .authorPrior }.map(\.exactText))
    }

    /// `author`: the author's name, and `signedAs` the names they signed
    /// earlier email with; their name and contact lines alone at the end
    /// ("Hi Sam,\nAuthor") are no content.
    static func hasContent(_ body: String, author: String? = nil, signedAs: Set<String> = []) -> Bool {
        // A greeting ("Leo,", «Olá, Sam,») and a closing with the name under
        // it («Atenciosamente,», "Alex Morgan"), in any app language, are no
        // content.
        let all = ComposerBoilerplate.strip(body, readingNames: true).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Each line with where it stood, so that lines next to each other
        // can be told from lines a blank line apart.
        var lines = all.indices.filter { !all[$0].isEmpty }.map { (index: $0, text: all[$0]) }
        // A salutation may open on two lines: "白子旭：" then "你好！".
        if let first = lines.first, ComposerBoilerplate.isGreeting(first.text) {
            lines.removeFirst()
            if let next = lines.first, ComposerBoilerplate.isSalutation(next.text) { lines.removeFirst() }
        }
        if var close = lines.lastIndex(where: { ComposerBoilerplate.isClosingLine($0.text) }), lines.count - close <= 4,
           lines[(close + 1)...].allSatisfy({ ComposerBoilerplate.isNameLine($0.text) || ComposerBoilerplate.isUnspacedName($0.text)
               || ComposerBoilerplate.isContactLine($0.text) }) {
            // A closing on two lines ("此致" then "敬礼！") goes whole; a thanks
            // a blank line above it is the body.
            if close > 0, ComposerBoilerplate.isClosingLine(lines[close - 1].text),
               lines[close - 1].index == lines[close].index - 1
                || Self.closingOpeners.contains(lines[close - 1].text.trimmingCharacters(in: .punctuationCharacters)) {
                close -= 1
            }
            lines.removeSubrange(close...)
        }
        // The author's name, and the contact lines under it; a line above it
        // too when it is their whole name or one they signed with ("Alex"
        // over "Alex R. Morgan"; "May" over "May Chen" is a month).
        if let author {
            var end = lines.count
            while end > 0, ComposerBoilerplate.isContactLine(lines[end - 1].text) { end -= 1 }
            if end > 0, ComposerBoilerplate.namesAuthor(lines[end - 1].text, author: author, signedAs: signedAs) {
                var start = end - 1
                while start > 0, ComposerContentText.folded(lines[start - 1].text) == ComposerContentText.folded(author)
                        || signedAs.contains(ComposerContentText.folded(lines[start - 1].text)) {
                    start -= 1
                }
                lines.removeSubrange(start...)
            }
        }
        return !lines.isEmpty
    }

    private static func candidate(_ output: ComposerModelOutput, request: ComposerGenerationRequest,
                                  enforceLanguage: Bool = true) throws -> String {
        guard output.completed else { throw ComposerContentError.incomplete("The model stopped before completing the email.") }
        let raw = output.text.lowercased()
        guard !["<think>", "</think>", "<thinking>", "</thinking>"].contains(where: raw.contains) else {
            throw ComposerContentError.incomplete("The model leaked its reasoning into the email.")
        }
        let body = GeneratedReplySanitizer.sanitize(output.text,
            stripTrailingQuotedBlock: request.content.mode == .reply,
            authorDisplayName: request.content.authorDisplayName,
            explicitInstructions: request.content.requirements.map(\.originalText))
        if enforceLanguage, let detected = wrongLanguage(body, requested: request.content.languageID) {
            throw ComposerContentError.incomplete("The model wrote in \(detected) instead of \(request.content.languageID).")
        }
        return try usableBody(body, request: request)
    }

    /// The language a draft is written in when it is not the requested one,
    /// read without its signature and sign-off (an English signature block
    /// under a short Japanese reply is not an English email); any kana makes
    /// a draft Japanese enough for a Japanese request.
    /// The family a short text's script points to when it is not the
    /// requested language's script; nil when it is, or cannot be told.
    static func scriptMismatch(_ text: String, requested: String) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        func share(_ test: (Unicode.Scalar) -> Bool) -> Double { Double(letters.filter(test).count) / Double(letters.count) }
        let kana = share { (0x3040...0x30FF).contains($0.value) }
        let han = share { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        let hangul = share { (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        let cyrillic = share { (0x0400...0x04FF).contains($0.value) }
        let latin = share { $0.isASCII || (0x00C0...0x024F).contains($0.value) }
        let found: String? = kana > 0 ? "ja" : han > 0.5 ? "zh" : hangul > 0.5 ? "ko" : cyrillic > 0.5 ? "ru" : latin > 0.5 ? "latin" : nil
        guard let found else { return nil }
        switch requested {
        case "ja": return kana > 0 || han > 0.5 ? nil : (found == "latin" ? "en" : found)
        case "zh": return han > 0.5 && kana == 0 ? nil : (found == "latin" ? "en" : found)
        case "ko": return found == "ko" ? nil : (found == "latin" ? "en" : found)
        case "ru": return found == "ru" ? nil : (found == "latin" ? "en" : found)
        default: return found == "latin" ? nil : found
        }
    }

    static func wrongLanguage(_ body: String, requested: String) -> String? {
        guard let requested = DraftLanguage.familyID(for: requested), requested != "und" else { return nil }
        let text = ComposerBoilerplate.stripForChecking(body)
        if requested == "ja", text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return nil }
        // Too few letters for the recognizer ("了解。" asked in Japanese):
        // the script must still be the language's own ("OK, I will come."
        // is not Japanese).
        let sample = text.isEmpty ? body : text
        guard sample.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 16 else {
            // A greeting or name above the reply may be in another script
            // ("Hi Sam,\n\n好的。"): the reply is the rest.
            var lines = sample.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.count > 1 { lines.removeFirst() }
            return scriptMismatch(lines.joined(separator: "\n"), requested: requested)
        }
        // Read among the languages the app writes, and the one asked for: a
        // short Russian reply is not Kazakh.
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Set(LocalModelLanguageSupport.supportedLanguageIDs.map { NLLanguage($0 == "zh" ? "zh-Hans" : $0) }
            + [NLLanguage("zh-Hant"), NLLanguage(requested == "zh" ? "zh-Hans" : requested)]).map { $0 }
        recognizer.processString(text.isEmpty ? body : text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first, top.value >= 0.5,
              let detected = DraftLanguage.familyID(for: top.key.rawValue), detected != requested else { return nil }
        return detected
    }

    /// The mechanical checks every email body passes, written or repaired.
    static func usableBody(_ body: String, request: ComposerGenerationRequest) throws -> String {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComposerContentError.incomplete("The model returned an empty email.")
        }
        guard !isDegenerate(body) else {
            throw ComposerContentError.incomplete("The model repeated itself instead of completing the email.")
        }
        guard !isSalutationOnly(body) else {
            throw ComposerContentError.incomplete("The model stopped after the salutation.")
        }
        let lowercased = body.lowercased()
        guard !lowercased.contains("</think>"), !lowercased.contains("</thinking>") else {
            throw ComposerContentError.incomplete("The model leaked its reasoning into the email.")
        }
        guard !repeatsCorrespondent(body, content: request.content) else {
            throw ComposerContentError.incomplete(copiedCorrespondent)
        }
        return body
    }

    static let copiedCorrespondent = "The model copied the correspondent's email instead of replying."
    static let greetedAuthor = "The model wrote the reply's greeting to you instead of to the person you are answering."

    /// Sentences shorter than this (folded) are stock courtesy ("Thank you
    /// for your email.") that a reply may share with any message.
    static let minimumRepeatedSentenceLength = 20
    /// The least repeated text that can make up a replay: more than one
    /// sentence, so restating a single fact back is never one.
    static let minimumRepeatedCharacters = 60
    static let minimumRepeatedSentences = 2

    /// A reply is the author's writing. A body whose substance is mostly
    /// sentences copied verbatim from the other party's mail (the incoming
    /// message or their earlier emails) hands their words back as the
    /// author's. The author's own earlier mail is not counted, alone or
    /// inside a compiled transcript ("you wrote" sections): re-sending it is
    /// a real request. Thread-state notes are not mail. Words the author's
    /// instructions or edits contain are the author's and never count.
    /// Against 651 sent emails and their correspondence, this flags none.
    static func repeatsCorrespondent(_ body: String, content: ComposerContentInput) -> Bool {
        let theirs = content.allEvidence
            .filter { ($0.role == .incoming || $0.role == .correspondent)
                && $0.source.kind != .memory && $0.source.kind != .threadState }
            .map { ComposerContentText.folded(otherPartyText($0.passageText)) }
        guard !theirs.isEmpty else { return false }
        let authored = (content.requirements.map(\.originalText) + content.manualEdits.map(\.replacement))
            .map(ComposerContentText.folded)
        var counted = 0
        var repeated = 0
        var repeatedSentences = 0
        for sentence in ComposerTextPassage.index(ComposerBoilerplate.strip(body, readingNames: true), prefix: "") {
            let key = ComposerContentText.folded(sentence.text)
            guard key.count >= minimumRepeatedSentenceLength else { continue }
            counted += key.count
            if theirs.contains(where: { $0.contains(key) }), !authored.contains(where: { $0.contains(key) }) {
                repeated += key.count
                repeatedSentences += 1
            }
        }
        return repeatedSentences >= minimumRepeatedSentences && repeated >= minimumRepeatedCharacters
            && repeated * 2 >= counted
    }

    /// A compiled transcript heads each message "<speaker> wrote · <date>",
    /// with "you wrote" for the author. Only the other speakers' sections
    /// count as theirs; text without headings is one speaker's.
    static func otherPartyText(_ text: String) -> String {
        var kept: [Substring] = []
        var authorSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains(" wrote · ") {
                authorSection = line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("you wrote")
                continue
            }
            if !authorSection { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// A bare salutation is evidence that generation stopped before writing
    /// the requested message. Genuinely concise replies stay valid.
    static func isSalutationOnly(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \Character.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.isEmpty == false }
        guard lines.count == 1 else { return false }
        let line = lines[0].folding(options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let greetings = ["hi", "hello", "hey", "dear", "greetings", "good morning", "good afternoon", "good evening"]
        for greeting in greetings {
            if line == greeting { return true }
            guard line.hasPrefix(greeting + " ") else { continue }
            let remainder = line.dropFirst(greeting.count + 1)
            guard remainder.isEmpty == false else { return true }
            if let separator = remainder.firstIndex(where: { $0 == "," || $0 == ":" || $0 == "，" || $0 == "、" }) {
                return remainder[remainder.index(after: separator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let recipientWordCount = remainder.split(whereSeparator: \Character.isWhitespace).count
            return recipientWordCount <= 4 && remainder.contains(where: { ".!?。！？".contains($0) }) == false
        }
        return false
    }

    /// Near-greedy decoding on an adapted model can loop. A sentence that
    /// recurs three times is never an email; rejecting it here spares the check.
    static func isDegenerate(_ body: String) -> Bool {
        var counts: [String: Int] = [:]
        for sentence in ComposerTextPassage.index(body, prefix: "") {
            let key = ComposerContentText.folded(sentence.text)
            guard key.count >= 12 else { continue }
            counts[key, default: 0] += 1
            if counts[key]! >= 3 { return true }
        }
        return false
    }
}

private actor ComposerStageRecorder {
    private(set) var stages: [ComposerPipelineStage] = []
    func append(_ stage: ComposerPipelineStage) { stages.append(stage) }
}
