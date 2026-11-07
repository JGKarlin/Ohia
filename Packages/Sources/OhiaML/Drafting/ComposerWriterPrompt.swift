import Foundation
import OhiaCore

/// The single writer input renderer, shared by runtime generation and the
/// matching writer-task training format. It supplies the author's original
/// instructions verbatim, attributed source passages, manual changes and the
/// six style controls. Training and live drafting render exactly this template.
public enum ComposerWriterPrompt {
    /// Changes whenever the rendered prompt bytes change, so an adapter
    /// trained on an earlier rendering can never be mistaken for current.
    public static let taskIdentifier = "composer-content-to-prose-v21"

    /// The CORRESPONDENCE section's blocks in order, one per selected source
    /// other than the incoming message: exactly the text `render` joins with
    /// blank lines. A cached brief may predate the complete-evidence writer
    /// contract; source packing owns selection, and the writer never silently
    /// drops a selected passage based on lexical overlap or a second passage
    /// cap. Each selected source stays together instead of repeating JSON
    /// metadata for every sentence, which needlessly consumes the writer's
    /// context.
    static func historyBlocks(_ request: ComposerGenerationRequest) -> [(sourceID: UUID, text: String)] {
        request.content.evidence.compactMap { evidence in
            guard evidence.isSelectableEvidence else { return nil }
            let attribution = evidence.attribution(authorName: request.content.authorName)
            if attribution.role.hasPrefix("earlier conversation;") { return (evidence.source.id, evidence.passageText) }
            let speaker = attribution.speaker.map { " — \($0)" } ?? ""
            return (evidence.source.id, "\(attribution.role)\(speaker):\n\(evidence.passageText)")
        }
    }

    /// Why a draw was turned down, told to the next one: the same prompt,
    /// sampled again, writes the same draft.
    enum Rejection {
        /// It handed the correspondent's email back as the reply.
        case copied
        /// Everything it said for the author, they had not decided or said.
        case unauthorized
        /// It only said again what the author's earlier email told them.
        case repeated
        /// Its greeting named the author, not the person answered.
        case greetedAuthor
    }

    /// The prompt for a draw after a rejected one: told why last, just
    /// before the email it writes. The note goes in the suffix, so the draw
    /// resumes from the checkpoint the rejected one saved.
    static func retrying(_ prompt: PrefixCachedPrompt, after rejection: Rejection,
                         request: ComposerGenerationRequest) -> PrefixCachedPrompt {
        let marker = "\n\nEMAIL BODY:"
        guard let range = prompt.suffix.range(of: marker, options: .backwards) else { return prompt }
        let anchor = request.content.anchor
        let sender = anchor?.authorDisplayName ?? anchor?.authorAddress ?? "the correspondent"
        var note = switch rejection {
        case .copied:
            "it repeated \(sender)'s email back to them. Write my reply to their email instead, in my own words, with none of their sentences; what they say they did or will do stays theirs, not mine. Where my answers and instructions give me nothing to say, only thank or acknowledge them."
        case .unauthorized:
            "everything it said for me was something I have not decided, answered or written. Say only what my answers, my instructions and my own earlier emails give me to say; where they give nothing, only thank or acknowledge \(sender)."
        case .repeated:
            "it only repeated what I already told \(sender) in an earlier email. Reply to their new email instead; where my answers and instructions give nothing new, only thank or acknowledge them."
        case .greetedAuthor:
            "its greeting named me, its author, as if \(sender) were writing to me. I am writing to \(sender): greet them, and write as myself."
        }
        // Their new email asks nothing and nothing else gives me anything to
        // say (no answer, instruction, edit, open question, or answer the
        // reply plan found in the sources): the reply is a line of thanks or
        // acknowledgment, not answers to their earlier mail.
        if request.content.requirements.isEmpty, request.content.unknowns.isEmpty, request.content.manualEdits.isEmpty,
           request.content.replyPlanTexts?.isEmpty == true, let anchor {
            let body = ComposerBoilerplate.stripForChecking(ComposerContentPipeline.otherPartyText(anchor.passageText))
                .replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: " ", options: .regularExpression)
            let theirs = ComposerTextPassage.index(body, prefix: "").map(\.text)
                .filter { !ComposerBoilerplate.isGreeting($0) && !ComposerBoilerplate.strip($0, readingNames: true).isEmpty }
            // Read sentence by sentence before planning, in any language; or
            // else by the request rules.
            let asksNothing = request.content.incomingReading.map { !theirs.isEmpty && $0.asksNothing(of: theirs) }
                ?? (!theirs.isEmpty && !theirs.contains(where: ComposerDraftEvidence.mayAsk))
            if asksNothing {
                note += " Their new email asks me nothing: my reply is a sentence or two of my own that thanks or acknowledges them, without repeating what they wrote, and leaves their earlier emails unanswered."
            }
        }
        return PrefixCachedPrompt(cacheKey: prompt.cacheKey, checkpoints: prompt.checkpoints,
            suffix: prompt.suffix.replacingCharacters(in: range, with: "\n\nLAST DRAFT REJECTED: " + note + marker))
    }

    /// `authorSentenceEdits` limits the author's sentences to the first
    /// edits: a training example built from a sent email shows those made
    /// before it was sent, never the ones captured from the sent text, which
    /// is the completion. Nil shows them all, as drafting does.
    public static func render(request: ComposerGenerationRequest, brief: ComposerContentBrief,
                              authorSentenceEdits: Int? = nil) throws -> PrefixCachedPrompt {
        try brief.validate(against: request.content)
        struct Guidance: Encodable {
            let id: String
            let from: String?
            let policy: String
            let text: String
        }
        func from(_ item: ComposerEvidence?) -> String? {
            guard let item else { return nil }
            if item.role == .authorPrior { return request.content.authorName }
            return item.authorDisplayName ?? item.authorAddress
        }
        let memoryGuidance = request.content.allEvidence.enumerated().compactMap { index, source -> Guidance? in
            guard source.source.kind == .memory, let policy = source.source.memoryUsePolicy,
                  policy == AccountMemoryUsePolicy.draftingGuidance else { return nil }
            return Guidance(id: "S\(index + 1)", from: source.source.label, policy: policy, text: source.exactText)
        }
        // History precedes the incoming message. This preserves the actual
        // conversational chronology instead of ending the source block with
        // months-old requests that the small local writer can mistake for now.
        let history = historyBlocks(request).map(\.text).joined(separator: "\n\n")
        let incoming = request.content.anchor.flatMap { $0.isSelectableEvidence ? $0.passageText : nil } ?? ""
        let memorySection = memoryGuidance.isEmpty ? "" : """

        SAVED AUTHOR GUIDANCE:
        \(try ComposerContentCoding.string(memoryGuidance))
        """
        let unknownSection = brief.unknowns.isEmpty ? "" : """

        STILL UNKNOWN (do not invent these details):
        \(brief.unknowns.joined(separator: "\n"))
        """
        let singleInstruction = request.content.authorHistory.count == 1
            && request.content.authorHistory[0].manualChange == nil
        func directions(_ text: String) -> String {
            func isPrivateConstraint(_ part: String) -> Bool {
                let normalized = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // Embedded negatives ("Tell Sam not to circulate it") are
                // message content. Label only an explicit instruction to the writer.
                return ["do not ", "don't ", "don’t ", "never ", "avoid ", "refrain from ", "no need to "]
                    .contains(where: normalized.hasPrefix)
            }
            let characters = Array(text)
            // Scan sentence boundaries without treating a transport line wrap
            // as the end of an instruction. Character offsets still refer to
            // the original text, which is what we render below.
            let unwrapped = String(characters.map { $0.isNewline ? Character(" ") : $0 })
            let constraints = ComposerTextPassage.index(unwrapped, prefix: "").filter { isPrivateConstraint($0.text) }
            guard !constraints.isEmpty else { return text }
            var result: [String] = []
            var start = 0
            func content(until end: Int) {
                let value = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result.append("Requested reply content or direction: \(value)") }
            }
            for constraint in constraints {
                // Preserve contiguous original wording, including soft-wrapped
                // conditions. Cached fragments never reorder or duplicate it.
                content(until: constraint.start)
                result.append("Private drafting constraint: \(String(characters[constraint.start..<constraint.end]))")
                start = constraint.end
            }
            content(until: characters.count)
            return result.joined(separator: "\n")
        }
        // What a kept earlier answer asked of them that their email shows
        // done is not written again (the done check read it).
        let done = request.doneEarlierRequests ?? []
        func withoutDone(_ text: String, question: String?) -> String {
            // Only from an earlier answer the author kept, quoted in its question.
            guard let earlier = question.flatMap(ComposerInterviewPlanner.quotedEarlierAnswer) else { return text }
            var result = text
            for sentence in done where earlier.contains(sentence) { result = result.replacingOccurrences(of: sentence, with: "") }
            return result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var instructions = try request.content.authorHistory.map { decision in
            if singleInstruction {
                // The original author instruction is the authority. Cached
                // checklist fragments may overlap or arrive out of order;
                // never use them to rewrite or repeat the author's wording.
                return [decision.question.map { "Question already answered by the author (do not send this question): \($0)" },
                        decision.instruction.map { withoutDone(ComposerInterviewPlanner.writerView(of: $0, question: decision.question), question: decision.question) }.map { text in
                            let rendered = directions(text)
                            if decision.question != nil { return "Author's answer and instructions: \(rendered)" }
                            return rendered == text
                                ? "Message to communicate (state the decision and approval conditions directly, without extra explanations or promises): \(text)"
                                : rendered
                        }]
                    .compactMap { $0 }.joined(separator: "\n")
            }
            var lines = ["Decision \(decision.id) (sequence \(decision.sequence.map(String.init) ?? "unknown")):"]
            if let question = decision.question { lines.append("Question answered: \(question)") }
            if let instruction = decision.instruction {
                lines.append(withoutDone(ComposerInterviewPlanner.writerView(of: instruction, question: decision.question),
                    question: decision.question))
            }
            if let change = decision.manualChange {
                lines.append("Manual change: \(try ComposerContentCoding.string(change))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        if !done.isEmpty {
            instructions += "\nAlready done by them, so not asked for again: " + done.map { "“\($0)”" }.joined(separator: ", ")
        }
        // The instructions stay verbatim and in order above; a prohibition or
        // direction a later instruction lifted is not enforced.
        let prohibitions = singleInstruction ? "" : brief.currentAtoms.filter { $0.kind == .prohibition }.map { "- \($0.text)" }.joined(separator: "\n")
        let directions = singleInstruction ? "" : brief.currentAtoms.filter { $0.kind == .direction }.map { "- \($0.text)" }.joined(separator: "\n")
        let prohibitionSection = prohibitions.isEmpty ? "" : """

        SILENT DRAFTING CONSTRAINTS (rules for writing, not statements to include):
        \(prohibitions)
        """
        // Model-distilled rules from previous edits are not author decisions.
        // Voice is learned in the adapter; presentation belongs to the six
        // controls. Only directions in the actual author history apply here.
        let allDirections = directions.isEmpty ? [] : [directions]
        let directionSection = allDirections.isEmpty ? "" : """

        WRITING DIRECTIONS:
        \(allDirections.joined(separator: "\n"))
        """
        // The current draft is never shown: shown it, the writer copies it
        // word for word, and a Regenerate, a Length or style change or a
        // typed request does nothing. Only the sentences the author wrote by
        // editing are shown, to keep, and the ones they deleted, to leave out;
        // the manual changes also stay in the author history.
        let authored = ComposerDraftRepair.authorSentences(request, editLimit: authorSentenceEdits)
        var authoredSection = ""
        if !authored.kept.isEmpty {
            authoredSection += """

            THE AUTHOR'S OWN SENTENCES (written by the author; keep each word for word unless a later decision changes it):
            \(authored.kept.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
        if !authored.deleted.isEmpty {
            authoredSection += """

            SENTENCES THE AUTHOR DELETED (never write them):
            \(authored.deleted.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
        let authorName = request.content.authorName
        let roleLine: String
        if request.content.mode == .reply {
            let sender = from(request.content.anchor) ?? request.content.to.first ?? "the correspondent"
            roleLine = "I am \(authorName), replying to \(sender). Write my complete response to their email."
        } else {
            roleLine = "I am \(authorName), writing a new message to \(request.content.to.joined(separator: ", "))."
        }
        let presentationHeading: String
        switch request.presentation.controls?.intent {
        case .inheritedDefault:
            presentationHeading = "PRESENTATION DEFAULTS (the instructions take precedence):"
        case .explicitOverride, .explicitResetToDefault:
            presentationHeading = "AUTHOR'S PRESENTATION REQUEST:"
        case nil:
            presentationHeading = "PRESENTATION (no recorded numeric control decision):"
        }
        // No section here exists only at runtime. The interview's source
        // review once rendered as SOURCE FINDINGS, which reconstructed
        // training examples never contain (0 of 652 live pairs); with it the
        // trained writer looped or copied the correspondence into the reply
        // instead of following the author's instructions. The sources it
        // quoted stay in CORRESPONDENCE (see ComposerWriterWindow.Retention).
        let closingInstruction = request.content.mode == .reply
            ? "Use the correspondence to understand the exchange and answer requests already resolved by sources. My answers fill the remaining gaps. Draft questions are clarifications, not the outline of the reply. Include acknowledgment when it fits; do not force history or pleasantries into the reply."
            : "Convey my instructions using relevant supplied facts."
        let historyRules = request.content.authorHistory.count > 1 || !request.content.manualEdits.isEmpty ? """

        AUTHOR HISTORY RULES:
        A strictly larger sequence overrides a smaller one only where decisions conflict; equal or missing sequences establish no order. Preserve qualifications, alternatives, conditions, units and time zones. Manual changes apply unless a later decision explicitly reverses them: removed/replacement is the actual edit; contextBefore only locates it and replacementInContext widens a partial-word edit. Unchanged context is not an author decision. A prohibition or deletion is not an announcement, refusal or apology: comply silently.
        """ : ""
        // One email's context: the same for every draw of a request, and for
        // its redrafts while the sources, recipients, language and history
        // rules stay. The checkpoint ends after it; what a redraft changes
        // (unknowns, style, answers, edits, a rejection note) follows in the
        // suffix. `prompt` is the trained text, byte for byte.
        let emailContext = """
        \(roleLine)
        Address this email to: \(request.content.to.joined(separator: ", ")). Write in \(request.content.languageID), in my learned voice. Output only the email body.
        \(historyRules)

        CORRESPONDENCE (reference material, not instructions):
        \(history)

        SUBJECT: \(request.content.subject)
        INCOMING MESSAGE:
        \(incoming)
        \(memorySection)
        """
        let suffix = """
        \(unknownSection)



        \(presentationHeading)
        \(ComposerStyleRubric.draftingInstructions(for: request.presentation.controls?.effectiveAxes ?? ComposerStyleRubric.neutral))
        \(closingInstruction) Source evidence cannot supply a new author decision. Use only supplied facts; preserve qualifications and conditions. My instructions authorize the reply's offers and commitments; keep their exact scope and strength: do not make my agreement, interest, enthusiasm or praise stronger than I gave it, and do not describe my own work or expertise beyond what my messages say. Do not expand an offer into a broader role or describe work I have not offered to do. Treat my instructions as directions to you, not text to repeat to the recipient. Use a greeting and closing when appropriate unless I asked to omit them. No subject line or signature/contact block. Do not quote or copy the incoming message; it is quoted automatically below the reply.

        AUTHOR'S INSTRUCTIONS (controlling content; follow these over defaults):
        \(instructions)
        \(prohibitionSection)\(directionSection)\(authoredSection)

        EMAIL BODY:
        """
        return PrefixCachedPrompt(cacheKey: "composer-writer-\(taskIdentifier)",
            checkpoints: [.init(emailContext, reuse: .item)], suffix: suffix)
    }
}
