import Foundation
import OhiaCore

/// Source-linked decisions about what helps the reply. These are not new
/// author instructions. Original instructions and evidence remain authoritative.
public struct ComposerReplyPlan: Codable, Sendable, Equatable {
    public struct Passage: Codable, Sendable, Equatable {
        public enum Use: String, Codable, Sendable {
            case required = "required"
            case answerContext = "answer"
            case acknowledge = "acknowledge"
            case develop = "detail"
            case background = "omit"
        }
        public let id: String
        public let use: Use
        /// Neutral source meaning with people named explicitly, not draft prose.
        /// Background is deliberately not rewritten into an outgoing statement.
        public let statement: String?

        public init(id: String, use: Use, statement: String?) {
            self.id = id
            self.use = use
            self.statement = statement
        }
    }

    public let passages: [Passage]

    public init(passages: [Passage]) { self.passages = passages }

    func validate(passages originals: [ComposerBriefPassage]) throws {
        guard passages.count == originals.count,
              Set(passages.map(\.id)) == Set(originals.map(\.id)),
              passages.allSatisfy({ passage in
                  let hasStatement = !(passage.statement?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                  return passage.use == .background || hasStatement
              }) else {
            throw ComposerContentError.invalidBrief("The reply plan must account for every source passage exactly once, with source meaning for each usable point.")
        }
    }

    /// Mandatory answer context stays constant. Length only admits additional
    /// useful acknowledgments/development; background can never enter this pool.
    func selected(length: Int?, additionalSourcePassageIDs: Set<String>) -> [Passage] {
        let context = passages.filter { $0.use == .answerContext || $0.use == .required }
        let optional = passages.filter {
            $0.use == .acknowledge || ($0.use == .develop && additionalSourcePassageIDs.contains($0.id))
        }
        let count: Int
        if let length {
            let fraction = Double(max(0, min(9, length - 1))) / 9
            count = Int((Double(optional.count) * fraction).rounded(.up))
        } else {
            count = min(1, optional.count)
        }
        return context + optional.prefix(count)
    }
}

enum ComposerReplyPlanning {
    static let answerTokens = 1_536

    struct Prepared: Sendable {
        let brief: ComposerContentBrief
        let plan: ComposerReplyPlan
    }

    private struct Response: Decodable { let passages: [ComposerReplyPlan.Passage] }

    static func prepare(_ input: ComposerContentInput, generate: ComposerModelCall) async throws -> Prepared {
        try input.validate()
        let passages = ComposerContentPreparer.rankedPassages(input)
        struct Source: Encodable {
            let id: String
            let speaker: String?
            let addressee: String?
            let role: ComposerEvidenceRole
            let text: String
        }
        let evidence = Dictionary(uniqueKeysWithValues: input.allEvidence.map { ($0.source.id, $0) })
        let sources = passages.map { passage in
            let source = evidence[passage.sourceID]
            return Source(id: passage.id,
                speaker: passage.role == .authorPrior ? "AUTHOR"
                    : passage.role == .incoming ? "CORRESPONDENT"
                    : source?.authorDisplayName ?? source?.authorAddress,
                addressee: passage.role == .incoming ? "AUTHOR" : nil,
                role: passage.role, text: passage.text)
        }
        let prompt = """
        Prepare the content for an email by \(input.authorName) to \(input.to.joined(separator: ", ")).
        AUTHOR is \(input.authorName). CORRESPONDENT is the incoming sender.
        The reply must answer the author's instructions, not summarize the incoming email.
        Return one JSON object with two arrays: "units" and "passages".

        PASSAGES: classify all \(passages.count) supplied source passages, including greetings.
        Use exactly one of these five actions for each passage:
        - "required": a source fact needed to obey an explicit author instruction, including
          requested acknowledgments or details. This takes priority over all other actions.
          For example, "Include the venue from the invitation" requires the venue passage;
          "Thank them for using my book" requires the book feedback passage.
          Required facts remain available at every Length, including facts from the incoming email.
        - "answer": a substantive question/request addressed to the author, or a condition of it.
          The writer needs this to answer. A request is NEVER "acknowledge" or "detail".
        - "acknowledge": personal news, feedback about the author's work, or a thoughtful gesture.
          Respond briefly to its significance. Greetings and self-introductions are not news.
        - "detail": information from an added source that helps explain the author's reply.
          Incoming administrative facts are omit unless an author instruction requires them.
        - "omit": greetings, self-introductions, repeated information, administrative descriptions,
          or sender-known details that do not help communicate the response.
        Choose by conversational purpose, not keyword overlap or a desire to make the email longer.
        Put useful optional points in priority order. The author may have nothing useful to add.
        For every point except omit, give a short neutral statement of the source meaning using
        AUTHOR and CORRESPONDENT for those two participants, other people's names for third parties.
        Do not use I, you, he, she, they, my, your, his, her or their in the statement.
        Resolve I/my to that source's speaker and you/your to
        its addressee, not to the outgoing email's recipient. If the referent is unknown, preserve
        that uncertainty; do not invent a person or decision. Preserve conditions and permissions.
        Describe requests as requests and permissions as permissions, never as the author's decision.
        Do not write email prose, feelings, new promises or repeated acknowledgments in this plan.
        For omit, omit statement. Planning cannot change the author's original instructions.

        UNITS: split each author's instruction into verbatim fragments; never paraphrase or infer a
        decision from a source. Include facts, answers, questions, offers and each qualifier (date,
        time zone, duration, condition, alternative). kind is content, prohibition (something the
        writer must not say or promise), or direction (language, tone or formatting).
        Copy requirementID from the instruction id. Do not extract units from manualChange entries.
        A manualChange records only removed/replacement; other text locates the edit.
        Mark a unit supersededBy only when a STRICTLY LATER sequence reverses that decision.
        New detail about another topic changes nothing. Missing/equal sequence cannot supersede.

        Output schema:
        {"units":[{"requirementID":"instruction id","text":"verbatim fragment","kind":"content"}],"passages":[{"id":"source passage id","use":"answer","statement":"neutral meaning with named people"},{"id":"another source passage id","use":"omit"}]}
        Every ID in \(try ComposerContentCoding.string(passages.map(\.id))) must occur exactly once in passages.
        INSTRUCTIONS: \(try ComposerContentCoding.string(input.authorHistory))
        SOURCES: \(try ComposerContentCoding.string(sources))
        """
        // Made once per request: no later call shares its leading text.
        let output = try await generate(PrefixCachedPrompt(cacheKey: "composer-reply-plan", prompt: prompt),
            .preparer, answerTokens)
        guard output.completed else { throw ComposerContentError.incomplete("Reply planning ended before completing.") }
        let response = try ComposerContentCoding.decodeModelObject(Response.self, from: output.text)
        let plan = ComposerReplyPlan(passages: response.passages)
        try plan.validate(passages: passages)
        // Decode/validate the units from the SAME model response. This closure
        // supplies already-returned data; it performs no additional inference.
        var brief = try await ComposerContentPreparer.prepare(input) { _, _, _ in output }
        brief.replyPlan = plan
        try brief.validate(against: input)
        return Prepared(brief: brief, plan: plan)
    }
}
