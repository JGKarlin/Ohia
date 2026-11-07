import Foundation
import OhiaCore

public struct ComposerPublicationFinding: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case omission, unauthorizedPosition, unsupportedClaim, prohibited, manualEdit, presentation
        /// A sentence decides a question the author skipped or left open.
        case undecided
        /// A sentence hands the other party's own words back as the author's.
        case misattribution
        /// A sentence repeats an earlier sentence of the draft, or says again
        /// what the author's earlier email already told these recipients.
        case repetition
    }
    public var kind: Kind
    public var requirementIDs: [String]
    public var candidateQuote: String?
    public var explanation: String
    /// The draft sentence (`C…`) the finding is about, when it is about one:
    /// the one sentence the repair may change for it.
    public var sentenceID: String?

    public init(kind: Kind, requirementIDs: [String], candidateQuote: String?, explanation: String,
                sentenceID: String? = nil) {
        self.kind = kind
        self.requirementIDs = requirementIDs
        self.candidateQuote = candidateQuote
        self.explanation = explanation
        self.sentenceID = sentenceID
    }
}

/// The one semantic check a draft gets: a compact, non-reasoning call on base
/// weights. The model answers two narrow questions: which draft sentence
/// expresses each content checklist item, and what kind of sentence each
/// draft sentence is and what supports it. Application code turns those
/// answers into findings; the model never decides acceptance. Prohibitions
/// are never presence-checked: a sentence that states, promises, refuses or
/// apologizes for a prohibited thing is the violation. Units a later
/// instruction replaced are never required: a sentence that still asserts one
/// as the author's current position is the violation. A question the author
/// skipped stays undecided: a sentence that decides it is the violation.
/// Repetition and the other party's words handed back as the author's are
/// found by the application, not the model.
public struct ComposerPublicationAudit: Codable, Sendable, Equatable {
    public struct ChecklistResult: Codable, Sendable, Equatable {
        public var id: String
        public var sentenceID: String?
        /// The item only says how to write; nothing in the draft states it.
        public var isDirection: Bool = false

        public init(id: String, sentenceID: String?, isDirection: Bool = false) {
            self.id = id
            self.sentenceID = sentenceID
            self.isDirection = isDirection
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            sentenceID = try container.decodeIfPresent(String.self, forKey: .sentenceID)
            isDirection = try container.decodeIfPresent(Bool.self, forKey: .isDirection) ?? false
        }
    }

    /// The checklist answer for an item that is a writing direction.
    static let styleMarker = "style"
    public struct SentenceResult: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case courtesy, fact, position, refusal, question }
        public var id: String
        public var kind: Kind
        public var references: [String]
    }
    public var checklist: [ChecklistResult]
    public var sentences: [SentenceResult]
    public var findings: [ComposerPublicationFinding]
    /// Earlier checklist items and manual changes the check did not say
    /// were kept or replaced by a later decision. Each may or may not still
    /// stand, so none was required and none was forbidden.
    public var unresolved: [String]
    /// Checklist items and draft sentences the check's answer did not read:
    /// an item it left out or matched to no sentence (neither required nor
    /// waived), a sentence it left out (judged only by the deterministic rules).
    public var unread: [String]
    /// Decisions a later instruction replaced, as the checklist words them.
    /// A repair must never state them again.
    public var replaced: [String]
    /// The removals leave nothing of the author's that speaks of the
    /// conversation: the draft is not sent, and the author is asked.
    public var nothingLeft: Bool?
    public var accepted: Bool { findings.isEmpty }

    public init(checklist: [ChecklistResult], sentences: [SentenceResult], findings: [ComposerPublicationFinding],
                unresolved: [String] = [], unread: [String] = [], replaced: [String] = [], nothingLeft: Bool? = nil) {
        self.checklist = checklist
        self.sentences = sentences
        self.findings = findings
        self.unresolved = unresolved
        self.unread = unread
        self.replaced = replaced
        self.nothingLeft = nothingLeft
    }

    struct ChecklistItem: Encodable, Sendable {
        let id: String
        let text: String
        /// The requirement a finding names; not sent to the model.
        let requirementID: String
        enum CodingKeys: String, CodingKey { case id, text }
    }

    /// Current content atoms plus the author's manual replacements. A
    /// replacement is checked as the words the author wrote, widened to the
    /// word they sit in, and located for the checker by the sentence they
    /// replaced; the unchanged rest of that sentence is never itself
    /// required, so generated wording the author left alone acquires no
    /// authority. Prohibitions, writing directions and superseded units are
    /// not presence-checked; a deletion is checked deterministically at its
    /// anchor and listed for the checker so a restoration in other words is
    /// cited (`removals`).
    static let answerMarker = "\nAuthor's answer: "

    /// Initialisms in a text, lowercased ("CV", "PDF", "ДНК"): what is asked
    /// for when no word of it is long enough to compare.
    static func initialisms(_ text: String) -> Set<String> {
        let folded = text.precomposedStringWithCompatibilityMapping
        let range = NSRange(folded.startIndex..., in: folded)
        return Set(initialism.matches(in: folded, range: range).compactMap { Range($0.range, in: folded).map { folded[$0].lowercased() } })
    }
    private static let initialism = try! NSRegularExpression(
        pattern: #"(?<![\p{Latin}\p{Cyrillic}\p{Greek}\p{N}])\p{Lu}[\p{Lu}\p{N}]+(?![\p{Latin}\p{Cyrillic}\p{Greek}\p{N}])"#)

    /// A checklist item's own words: an answer without the question it answers.
    static func authorsWords(_ itemText: String) -> String {
        itemText.components(separatedBy: answerMarker).last ?? itemText
    }

    /// A checklist item's question, if it answers one.
    static func askedOfAuthor(_ itemText: String) -> String? {
        guard let range = itemText.range(of: answerMarker), itemText.hasPrefix("Question: ") else { return nil }
        return String(itemText[itemText.index(itemText.startIndex, offsetBy: "Question: ".count)..<range.lowerBound])
    }

    static func checklist(request: ComposerGenerationRequest, brief: ComposerContentBrief) -> [ChecklistItem] {
        let requirements = Dictionary(uniqueKeysWithValues: request.content.requirements.map { ($0.id, $0) })
        let content = brief.currentAtoms.filter { $0.kind == .content }
        // What an earlier answer the author keeps asked of the recipient, and
        // the email being answered shows done ("Please send me your
        // transcripts" to the student who just sent them), is not owed again;
        // said again, it repeats the earlier email. The done check reads it.
        let done = Set(request.doneEarlierRequests ?? [])
        var items = content.filter { atom in
            guard done.contains(atom.text), let requirement = requirements[atom.requirementID],
                  requirement.origin == .interviewAnswer,
                  let earlier = requirement.questionText.flatMap(ComposerInterviewPlanner.quotedEarlierAnswer),
                  flattened(earlier).contains(flattened(atom.text)) else { return true }
            return false
        }.map {
            let prefix = requirements[$0.requirementID]?.questionText.map { "Question: \($0)" + answerMarker } ?? ""
            return ChecklistItem(id: $0.id, text: prefix + $0.text, requirementID: $0.requirementID)
        }
        for (index, edit) in request.content.manualEdits.enumerated() {
            let replacement = anchoredReplacement(edit)
            guard !replacement.isEmpty else { continue }
            let original = edit.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = edit.contextBefore?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text: String
            if !context.isEmpty, !original.isEmpty {
                text = "\(replacement) (the author's replacement for “\(original)” in “\(context)”)"
            } else if !context.isEmpty {
                text = "\(replacement) (the author's addition to “\(context)”)"
            } else {
                text = replacement
            }
            items.append(ChecklistItem(id: "M\(index + 1)", text: text, requirementID: "M\(index + 1)"))
        }
        return items
    }

    /// The replacement widened to the Latin word or number it sits in, so a
    /// character-level change ("attend" → "attended" records "ed") is checked
    /// as the word the author wrote. The replacement is read at its recorded
    /// offset in the edited sentence, never at an earlier copy of the same
    /// characters ("ed" inside "requested"). Expansion stops at whitespace,
    /// punctuation and CJK characters, which are their own units.
    static func anchoredReplacement(_ edit: ComposerManualEdit) -> String {
        edit.anchoredReplacement
    }

    static func prohibitions(brief: ComposerContentBrief) -> [ChecklistItem] {
        brief.currentAtoms.filter { $0.kind == .prohibition }.map { ChecklistItem(id: $0.id, text: $0.text, requirementID: $0.requirementID) }
    }

    /// Wording the author deleted, supplied so a sentence that restores its
    /// meaning in other words can be cited; the literal anchor is enforced
    /// deterministically in `manualEditFindings`. A partial deletion names
    /// the sentence it came from.
    static func removals(request: ComposerGenerationRequest) -> [ChecklistItem] {
        request.content.manualEdits.enumerated().compactMap { index, edit in
            let original = edit.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, edit.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let context = edit.contextBefore?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = context.isEmpty || context == original ? original : "\(original) (removed from “\(context)”)"
            return ChecklistItem(id: "M\(index + 1)", text: text, requirementID: "M\(index + 1)")
        }
    }

    /// Content units a later instruction replaced, supplied so a sentence
    /// still asserting one as current can be cited. A lifted prohibition has
    /// nothing to assert and is simply no longer enforced.
    static func superseded(brief: ComposerContentBrief) -> [ChecklistItem] {
        brief.supersededAtoms.filter { $0.kind == .content }.map { ChecklistItem(id: $0.id, text: $0.text, requirementID: $0.requirementID) }
    }

    private struct Response: Decodable {
        struct ManualResolution: Decodable {
            let id: String
            let supersededBy: String?
        }
        struct Check: Decodable {
            let id: String
            let sentence: String?
        }
        struct Sentence: Decodable {
            let id: String
            let kind: SentenceResult.Kind
            let refs: [String]?
        }
        let checklist: [Check]
        let sentences: [Sentence]
        let manualResolutions: [ManualResolution]?
        let itemResolutions: [ManualResolution]?
        let overstates: IDList?
        let promises: IDList?
        let credits: IDList?
    }

    /// The answer with two slips of punctuation the model makes undone: a
    /// comma just before a closing bracket (`],}`), and a key of the answer
    /// that lost its opening quote (`],overstates":[]`). Nothing is added
    /// or dropped that the answer says, except a tail the model looped into
    /// after the answer closed (`…"promises":["C8"]},{"id":"C10",…`): the
    /// first whole object is the answer. A close just before more of its own
    /// keys (`…]},"promises":["C3"]}`) is a slip, not its end, and a key it
    /// gives again has looped: the answer ends before it, as first given.
    /// Tried only on an answer that does not read as it is; a fenced answer
    /// is read strictly, never mended.
    static func mendedAnswer(_ text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") else { return nil }
        var output = "", inString = false, escaped = false, pendingComma = false
        for character in text {
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            if character == "," { if pendingComma { output.append(",") }; pendingComma = true; continue }
            if character.isWhitespace { output.append(character); continue }
            if pendingComma, character != "}", character != "]" { output.append(",") }
            pendingComma = false
            if character == "\"" { inString = true }
            output.append(character)
        }
        if pendingComma { output.append(",") }
        let keys = "checklist|sentences|manualResolutions|itemResolutions|overstates|promises|credits"
        output = output.replacingOccurrences(of: #"([,{]\s*)("# + keys + #")""#, with: "$1\"$2\"", options: .regularExpression)
        // The answer ends where its first whole value closes.
        let moreKeys = try! NSRegularExpression(pattern: #"^\s*,\s*"(?:"# + keys + #")"\s*:"#)
        // `keyStart`: where a key's opening quote sits in `cut`, in UTF-8 offsets.
        var cut = "", depth = 0, keyStart: Int?, seenKeys = Set<String>()
        // The answer as it stood at a close read as a slip, should what
        // follows it never close; and the closers still owed.
        var atSlip: String?
        var owed: [Character] = []
        inString = false
        escaped = false
        var index = output.startIndex
        scan: while index < output.endIndex {
            let character = output[index]
            defer { index = output.index(after: index) }
            if inString {
                cut.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                    inString = false
                    // A key of the answer it gives a second time: it looped.
                    if let offset = keyStart {
                        keyStart = nil
                        let start = cut.utf8.index(cut.utf8.startIndex, offsetBy: offset)
                        let key = String(cut[cut.index(after: start)..<cut.index(before: cut.endIndex)])
                        if !seenKeys.insert(key).inserted {
                            cut = String(cut[..<start])
                            while let last = cut.last, last.isWhitespace || last == "," { cut.removeLast() }
                            cut.append("}")
                            depth = 0
                            break scan
                        }
                    }
                }
                continue
            }
            if character == "\"" {
                inString = true
                // A string at the top level after its opening or a comma is a key.
                if depth == 1, let previous = cut.last(where: { !$0.isWhitespace }), previous == "{" || previous == "," {
                    keyStart = cut.utf8.count
                }
            } else if character == "{" || character == "[" {
                depth += 1
                owed.append(character == "{" ? "}" : "]")
            } else if character == "}" || character == "]" {
                depth -= 1
                _ = owed.popLast()
                if depth == 0 {
                    let rest = String(output[output.index(after: index)...])
                    if character == "}",
                       moreKeys.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil {
                        if atSlip == nil { atSlip = cut + "}" }
                        depth = 1
                        owed = ["}"]
                        continue
                    }
                    cut.append(character)
                    break
                }
            }
            cut.append(character)
        }
        // Cut off after a slip: what it gave since is closed where it
        // stopped when that reads as an answer ("promises":["C1"), else the
        // answer is read as it stood at the slip.
        if depth > 0, let atSlip {
            var closed = cut
            while let last = closed.last, last.isWhitespace || last == "," { closed.removeLast() }
            closed += String(owed.reversed())
            let reads = !inString && (try? JSONDecoder().decode(Response.self, from: Data(closed.utf8))) != nil
            cut = reads ? closed : atSlip
        }
        output = cut
        return output == text ? nil : output
    }

    /// Sentence IDs as strings or {"id": …} objects; any other shape names
    /// none rather than throwing the whole check away.
    struct IDList: Decodable {
        let ids: [String]
        private struct Entry: Decodable { let id: String }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let strings = try? container.decode([String].self) {
                ids = strings
            } else if let entries = try? container.decode([Entry].self) {
                ids = entries.map(\.id)
            } else {
                ids = []
            }
        }
    }

    /// Checklist items from an instruction a strictly later author decision
    /// could have replaced ("I can attend Monday", then "Actually, Tuesday
    /// only"). Nothing marks that in advance, so the check says which were
    /// replaced; a replaced item is no longer required, and asserting it is
    /// the finding.
    static func replaceableItemIDs(request: ComposerGenerationRequest,
                                   items: [ChecklistItem]) -> [String] {
        let history = request.content.authorHistory
        return items.filter { item in
            !item.id.hasPrefix("M") && history.contains {
                request.content.isLaterAuthorDecision($0.id, than: item.requirementID)
            }
        }.map(\.id)
    }

    static func overridableManualIDs(request: ComposerGenerationRequest) -> [String] {
        request.content.manualEdits.indices.map { "M\($0 + 1)" }.filter { id in
            request.content.authorHistory.contains { request.content.isLaterAuthorDecision($0.id, than: id) }
        }
    }

    /// A number in a position sentence that no current instruction contains
    /// but a cited earlier message does. Width-folded so "１３" and "13" match.
    static func leakedNumber(in sentence: String, instructions: [String], earlierTexts: [String]) -> String? {
        let numbers = ComposerContentText.folded(sentence).split { !$0.isNumber }.map(String.init)
        guard !numbers.isEmpty else { return nil }
        let current = Set(instructions.flatMap { ComposerContentText.folded($0).split { !$0.isNumber }.map(String.init) })
        let earlier = Set(earlierTexts.flatMap { ComposerContentText.folded($0).split { !$0.isNumber }.map(String.init) })
        return numbers.first { !current.contains($0) && earlier.contains($0) }
    }

    /// Subject forms of the first person, by the draft's language. A word
    /// is read only in its own language: "je" is "is" in Czech, "i" is "and"
    /// in Polish and "the" in Italian. Possessives and objects ("my", "me")
    /// are not here: "You said my notes helped" is about the other person.
    /// Unspaced scripts often drop the subject; those sentences stay with
    /// the check's own reading.
    static let firstPersonSubjects: [String: Set<String>] = [
        "en": ["i", "i'll", "i'd", "i've", "i'm", "we", "we'll", "we'd", "we've", "we're"],
        "fr": ["je"], "de": ["ich", "wir"], "es": ["yo", "nosotros", "nosotras"],
        "it": ["io"], "pt": ["eu"], "nl": ["ik", "wij"],
    ]
    static let unspacedFirstPersonSubjects: [String: [String]] = [
        "ja": ["私は", "私が", "私も", "わたしは", "わたしが", "わたくしは", "わたくしが", "僕は", "僕が",
               "私自身", "わたし自身", "僕自身", "当方は", "当方で", "弊社は", "弊社で"],
        "zh": ["我会", "我已", "我将", "我是", "我在", "我想", "我们会", "我们已", "我们将", "我们是", "我们在"],
    ]
    /// Korean subject forms, read as whole words: "끝나는" holds "나는".
    static let koreanFirstPersonSubjects: Set<String> = ["저는", "제가", "나는", "내가", "저희는", "저희가"]
    /// Words before a Roman numeral "I" ("Chapter I", "World War I").
    static let numeralContexts: Set<String> = ["war", "chapter", "part", "phase", "volume", "vol", "section", "act",
        "book", "level", "type", "class", "grade", "stage", "appendix", "figure", "fig", "table", "article",
        "tier", "round", "schedule", "annex", "henry", "louis", "elizabeth", "charles", "george", "james"]

    /// Judgments of how well something fits the author's research,
    /// interests or program, or a named program, lab or department, in English
    /// and Japanese. Scheduling, capacity, policy and data comparisons ("fits
    /// with our lab's schedule", "fits within the limit", "align with Sam",
    /// 研究計画書は様式に合致) are not: a possessive ("our lab's …") names
    /// something else of the lab's.
    static let fitJudgmentPatterns = [
        #"\b(?:align(?:s|ed|ing)?|fit(?:s|ting)?|complement(?:s|ed|ing)?|resonat(?:es?|ing))\b[^.!?,;]{0,30}\b(?:my|our)\s+(?:own\s+)?(?:[\w-]+\s+){0,2}(?:research|interests?|work|program(?:me)?|lab(?:oratory)?|environment|expertise|field|agenda)\b(?!['’]s)(?!\s+(?:schedule|calendar|requirements?|guidelines?|setup|commitments?|hours|load|policy|policies|plan|plans|day|week|rules?|deadline|budget))"#,
        #"\b(?:my|our)\s+(?:own\s+)?(?:research(?:\s+interests?)?|interests?|work|lab['’]s\s+work)\b(?!['’]s)(?!\s+(?:schedule|calendar|requirements?|guidelines?|setup|commitments?|hours|load|policy|policies|plan|plans|day|week|rules?|deadline|budget))[^.!?,;]{0,30}\b(?:align|fit|complement|resonat|match)(?:s|es|ed|ing)?\b"#,
        #"\b(?:align(?:s|ed|ing)?|fit(?:s|ting)?|complement(?:s|ed|ing)?|resonat(?:es?|ing))\b[^.!?,;]{0,30}\bwith\s+the\s+(?:[\w-]+\s+){0,5}(?:program(?:me)?|research\s+environment|lab(?:oratory)?|curriculum)\b(?!['’]s)"#,
        #"\b(?:good|great|strong|excellent|natural|perfect|ideal)\s+fit\s+(?:here\b|for\s+us\b|(?:for|with)\s+(?:the|our|my)\s+(?:[\w-]+\s+){0,4}(?:program(?:me)?|lab(?:oratory)?|research|interests?|work)\b(?!['’]s))"#,
        #"\bwell[-\s]suited\s+(?:to|for)\s+(?:the|our|my)\s+(?:[\w-]+\s+){0,4}(?:program(?:me)?|lab(?:oratory)?|research)\b(?!['’]s)"#,
        #"\b(?:align(?:s|ed|ing)?|fit(?:s|ting)?|complement(?:s|ed|ing)?|resonat(?:es?|ing))\b[^.!?,;]{0,30}\bwith\s+(?:the|our|my)\s+(?:[\w-]+\s+){0,3}(?:program(?:me)?|lab(?:oratory)?|department|group)['’]s\s+(?:[\w-]+\s+){0,2}(?:focus|scope|goals?|mission|vision|aims?|priorities|themes?|direction|emphasis|research|interests?)\b"#,
        #"(?:ご研究|研究テーマ|研究内容|研究関心|ご関心|関心|ご専門(?!家)|プログラム|研究室(?:の(?:研究|テーマ))?)[^。]{0,30}(?:合致|ふさわしい|相性が(?:良|よ)い|親和性)"#
    ]
    /// A program named in capitals after "fit for" ("an excellent fit for
    /// MSDS", "a great fit for Northfield's program"), read in the original case.
    static let namedFitPattern = #"(?i:\b(?:good|great|strong|excellent|natural|perfect|ideal)\s+fit\s+(?:for|with)\s+)(?!(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|January|February|March|April|May|June|July|August|September|October|November|December)\b)[A-Z][\w’'-]*"#

    static func judgesFit(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased()
        return fitJudgmentPatterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
            || sentence.range(of: namedFitPattern, options: .regularExpression) != nil
    }

    /// A slot the writer left for text nobody gave ("[insert specific
    /// expertise if known]", "［氏名を記入］"); button labels ("[Add
    /// submission]", "the [Insert] menu") and form headings (【記入例】) are not.
    static func holdsPlaceholder(_ sentence: String) -> Bool {
        !placeholderSlots(in: sentence).isEmpty
    }

    /// The sentences past the salutation a draft needs before it can be
    /// mostly invented: in a short reply one stray sentence is not most.
    static let minimumSentencesForInventedDraft = 4

    /// The sentences copied word for word from the author's earlier email a
    /// draft needs to replay it: one repeated sentence is a restatement,
    /// which the restatement rule reads on its own.
    static let minimumReplayedSentences = 2

    /// A bracketed slot in a salutation, in any script's brackets.
    static let greetingSlot = try! NSRegularExpression(pattern: #"[\[［【〔][^\]］】〕\n]{1,40}[\]］】〕]"#)

    /// The writer slots a sentence holds, as written.
    static func placeholderSlots(in sentence: String) -> [String] {
        let lowered = sentence.lowercased()
        return [#"\[(?:insert|fill in)\s+[^\]]+\]"#, #"\[[^\]]*\b(?:if known|if applicable|otherwise keep|tbd)\b[^\]]*\]"#,
                #"[［【\[][^］】\]]{0,40}(?:を記入|を入力|を挿入)[^］】\]]*[］】\]]"#].flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(lowered.startIndex..., in: lowered)
            return regex.matches(in: lowered, range: range).compactMap { Range($0.range, in: lowered).map { String(lowered[$0]) } }
        }
    }

    /// Text compared across line wraps: whitespace runs read as one space.
    static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func hasFirstPersonSubject(_ sentence: String, languageID: String) -> Bool {
        // Quoted speech is the quoted person's.
        let unquoted = sentence.replacingOccurrences(of: #"[“"「『][^”"」』]*[”"」』]"#, with: " ", options: .regularExpression)
        let family = String(languageID.lowercased().prefix { $0 != "-" && $0 != "_" })
        if let forms = unspacedFirstPersonSubjects[family] { return forms.contains(where: unquoted.contains) }
        if family == "ko" {
            return unquoted.split { $0.isWhitespace || $0.isPunctuation }.contains { koreanFirstPersonSubjects.contains(String($0)) }
        }
        guard let forms = firstPersonSubjects[family] else { return false }
        let words = unquoted.split { !$0.isLetter && $0 != "'" && $0 != "’" }
            .map { String($0).replacingOccurrences(of: "’", with: "'") }
        return words.indices.contains { index in
            let word = words[index].lowercased()
            if family == "fr", word.hasPrefix("j'") { return true }
            guard forms.contains(word), !ComposerWriterTraining.isWrittenAsAcronym(word, in: sentence) else { return false }
            // A Roman numeral "I": after "Chapter" or "War", or ending the sentence.
            if word == "i" {
                guard index + 1 < words.count, words[index + 1].first?.isLowercase == true else { return false }
                if index > 0, numeralContexts.contains(words[index - 1].lowercased()) { return false }
            }
            return true
        }
    }

    /// The longest reference list the check may write for one sentence.
    /// Measured checks cite at most seven, nearly always five or fewer; a
    /// longer list is the model counting through passage IDs, past the ones
    /// that exist, until its token limit, and the draft went out unchecked.
    /// The list is closed here, and a list that reaches it is a count, not
    /// citations. A position or refusal on one stands only on the checklist
    /// items the check says the sentence expresses (and the author's own
    /// facts): left unread, an answer to a skipped question or a view nobody
    /// gave would pass unjudged. A fact or question on one is left unread,
    /// since its support may be in the count.
    static let maximumSentenceReferences = 8
    /// Commas one sentence entry ({"id","kind","refs":[…]}) may hold, so its
    /// reference list closes at `maximumSentenceReferences`. The answer's
    /// closing keys share the count after the last sentence, which still
    /// leaves room for several overstated, promising and crediting sentences.
    public static let answerCommaLimit = 2 + maximumSentenceReferences - 1

    /// Sized for a pretty-printed answer with several references a sentence,
    /// even though a compact one is requested: a cut-off answer is no check.
    static func answerTokens(checklistCount: Int, sentenceCount: Int) -> Int {
        min(2_048, 144 + checklistCount * 32 + sentenceCount * 66)
    }

    /// The manual-edit anchor: the sentence the author changed as it stood
    /// before the change, or the removed wording itself when no context was
    /// recorded. A draft that still carries the anchor, beyond any copy the
    /// author's own edited text keeps, has undone the edit; another sentence
    /// that happens to share the removed words has not.
    static func manualEditFindings(request: ComposerGenerationRequest, body: String,
                                   excluding superseded: Set<String> = []) -> [ComposerPublicationFinding] {
        var findings: [ComposerPublicationFinding] = []
        for (index, edit) in request.content.manualEdits.enumerated() {
            guard !superseded.contains("M\(index + 1)") else { continue }
            let original = edit.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = edit.contextBefore?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let anchor = context.isEmpty ? original : context
            guard !anchor.isEmpty else { continue }
            // An insertion leaves the sentence it went before unchanged.
            guard !original.isEmpty else { continue }
            // The copies the author kept: the editor text counts only for an
            // edit made on the generation it holds; an earlier generation may
            // already have lost the edit. Stricter than the restore, which
            // keeps the editor's copies whenever the editor holds the author's
            // version; the check reports them.
            let trusted = edit.baseRevisionID != nil && edit.baseRevisionID == request.displayedRevisionID
            let allowed = trusted ? request.currentBody.map { ComposerContentText.occurrences(of: anchor, in: $0) } ?? 0 : 0
            guard ComposerContentText.occurrences(of: anchor, in: body) > allowed else { continue }
            let removed = edit.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            findings.append(ComposerPublicationFinding(kind: .manualEdit, requirementIDs: ["M\(index + 1)"],
                candidateQuote: anchor, explanation: removed
                    ? "The author removed this wording; it must not reappear: “\(anchor)”"
                    : "The author replaced this wording; it must not reappear: “\(anchor)”"))
        }
        return findings
    }

    /// Questions the author skipped or has not reached, as the writer was
    /// told them, without the writer's instruction tail.
    static func undecided(request: ComposerGenerationRequest) -> [ChecklistItem] {
        request.content.unknowns.enumerated().compactMap { index, line in
            var text = line
            for marker in [": skipped — ", ": unanswered — "] {
                if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ChecklistItem(id: "U\(index + 1)", text: text, requirementID: "U\(index + 1)")
        }
    }

    /// The draft as the check reads it: sign-off and signature removed, then
    /// split into sentences. The repair edits these same sentences.
    static func sentences(of body: String) -> (text: String, sentences: [ComposerTextPassage]) {
        let checked = ComposerBoilerplate.stripForChecking(body)
        let text = checked.isEmpty ? body : checked
        return (text, ComposerTextPassage.index(text, prefix: "C"))
    }

    /// An undecided item on the author's earlier answer, read apart: the
    /// answer and their request (`ComposerInterviewDeferredVariable`).
    static func earlierAnswerParts(_ item: String) -> (answer: String, request: String)? {
        typealias Line = ComposerInterviewDeferredVariable
        // The checklist item has its status already cut (`undecided`); the
        // whole line still carries it.
        guard let start = item.range(of: Line.earlierAnswerOpening) else { return nil }
        let end = [true, false].compactMap { item.range(of: Line.earlierAnswerStatus(skipped: $0), options: .backwards) }
            .map(\.lowerBound).filter { $0 >= start.upperBound }.max() ?? item.endIndex
        let quoted = item[start.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)[...]
        // Their request is quoted last, so the last opening of it is the one.
        if quoted.hasSuffix(Line.theirRequestClosing),
           let split = quoted.range(of: Line.theirRequestOpening, options: .backwards) {
            return (String(quoted[..<split.lowerBound]),
                String(quoted[split.upperBound...].dropLast(Line.theirRequestClosing.count)))
        }
        guard quoted.hasSuffix(Line.earlierAnswerClosing) else { return nil }
        return (String(quoted.dropLast(Line.earlierAnswerClosing.count)), "")
    }

    /// Languages that write an ordinal number with a dot ("am 5. Juni"),
    /// where the sentence splitter cuts a date in two.
    static let ordinalLanguages: Set<String> = ["de", "da", "nb", "no", "nn", "fi", "cs", "sk", "sl", "hr", "sr",
        "bs", "pl", "hu", "tr", "et", "lv", "is", "fo"]

    /// The author's own earlier messages in this conversation. Restating one
    /// is grounded: it is what the author already said to these people. An
    /// earlier message from another conversation can supply a fact, never the
    /// author's position today.
    static func isConversationHistory(_ evidence: ComposerEvidence?) -> Bool {
        guard let evidence else { return false }
        return evidence.role == .authorPrior && evidence.source.kind == .thread
    }

    static func review(body: String, request: ComposerGenerationRequest,
                       brief: ComposerContentBrief,
                       generate: ComposerModelCall) async throws -> Self {
        var findings: [ComposerPublicationFinding] = []
        // Manual edits: the changed sentence must be gone. Whether the
        // author's replacement is expressed is a checklist question below.
        let items = checklist(request: request, brief: brief)
        let prohibited = prohibitions(brief: brief)
        let removed = removals(request: request)
        let replaced = superseded(brief: brief)
        let open = undecided(request: request)
        let candidates = sentences(of: body).sentences
        guard !candidates.isEmpty else {
            throw ComposerContentError.incomplete("The draft has no sentences to check.")
        }
        let evidence = Dictionary(uniqueKeysWithValues: request.content.allEvidence.map { ($0.source.id, $0) })
        struct Passage: Encodable {
            let id: String
            let from: String?
            let to: String?
            let role: String
            let text: String
        }
        let authorName = request.content.authorName
        // The author's own identity is supplied context: a self-introduction
        // ("I am Morgan of the admissions committee") is grounded, not invented.
        let passages = [Passage(id: "AUTHOR", from: authorName, to: nil, role: "the author's identity",
            text: request.content.identityAddress.isEmpty ? "The author of this email is \(authorName)."
                : "The author of this email is \(authorName) <\(request.content.identityAddress)>.")]
            + brief.passages.map { passage in
                let source = evidence[passage.sourceID]
                let from = passage.role == .authorPrior ? authorName
                    : (source?.authorDisplayName ?? source?.authorAddress ?? source?.source.label)
                let role = passage.role == .authorPrior
                    ? (isConversationHistory(source) ? "the author's earlier message in this conversation"
                        : "the author's message in another conversation")
                    : passage.role.displayLabel
                return Passage(id: passage.id, from: from,
                    to: passage.role == .incoming ? authorName : nil, role: role, text: passage.text)
            }
        let authorPriorIDs = Set(brief.passages.filter { $0.role == .authorPrior }.map(\.id))
        let conversationIDs = Set(brief.passages.filter { isConversationHistory(evidence[$0.sourceID]) }.map(\.id))
        // What this request adds to the rules, in the suffix: none of it
        // comes before the text other checks share.
        let prohibitionSection = prohibited.isEmpty ? "" : """
        PROHIBITIONS: things the instructions forbid. Cite a prohibition's ID in a sentence's
        refs ONLY if that sentence actually does the forbidden thing: it asserts or promises
        the forbidden content, or it announces, refuses, or apologizes about it. A sentence
        that concerns the same topic while complying (for example, asking whether a date works
        when told not to assume a date is agreed) is not a violation and must not cite it.
        \(try ComposerContentCoding.string(prohibited))
        """
        let removedSection = removed.isEmpty ? "" : """
        REMOVED BY THE AUTHOR: wording the author deleted from the draft. It is not required. Cite a
        removed ID in a sentence's refs ONLY if that sentence restores the removed statement, promise,
        offer, request or detail in any wording. A sentence on the same topic that does not restore
        it must not cite it.
        \(try ComposerContentCoding.string(removed))
        """
        let supersededSection = replaced.isEmpty ? "" : """
        SUPERSEDED: earlier decisions a later instruction replaced. They are not required. Cite a
        superseded ID in a sentence's refs ONLY if that sentence asserts the earlier decision as the
        author's current position, plan, date or availability. A sentence that states the replacing
        decision, or that corrects or withdraws the earlier one, must not cite it.
        \(try ComposerContentCoding.string(replaced))
        """
        let undecidedSection = open.isEmpty ? "" : """
        UNDECIDED: questions the author has not answered. A position or refusal cites an undecided ID
        when it answers that question for the author: it accepts, agrees, declines, offers, commits
        to a time or availability, or states a preference on it. A question cites it when it asks the
        recipient about it.
        \(try ComposerContentCoding.string(open))
        """
        let overridable = overridableManualIDs(request: request)
        let replaceable = replaceableItemIDs(request: request, items: items)
        struct ItemSource: Encodable { let item: String; let decision: String }
        let historySection = overridable.isEmpty && replaceable.isEmpty ? "" : """
        AUTHOR HISTORY: original instructions and explicit manual changes, with their sequence.
        Only removed/replacement in a manualChange are author edits; context locates the edit
        but does not make unchanged generated words authoritative.
        \(try ComposerContentCoding.string(request.content.authorHistory))
        """
        let itemResolutionSection = replaceable.isEmpty ? "" : """
        CHECKLIST ITEM SOURCES: \(try ComposerContentCoding.string(items.filter { replaceable.contains($0.id) }
            .map { ItemSource(item: $0.id, decision: $0.requirementID) }))
        For EVERY id in \(try ComposerContentCoding.string(replaceable)), return an itemResolutions
        entry {"id":"A1","supersededBy":null}, or the id of a STRICTLY LATER author decision that
        contradicts, withdraws or replaces that item. New detail or another topic replaces nothing.
        A later decision that holds back what an item approved, agreed to or let go ahead (asks
        them to wait, says not yet, or needs another look at it first) withdraws that item, and
        any judgment the item gave of the same thing.
        A replaced item is no longer required (its checklist sentence may be null). Cite a replaced
        item's ID in sentence refs only if the sentence still asserts that old decision as current.
        """
        let manualResolutionSection = overridable.isEmpty ? "" : """
        For EVERY id in \(try ComposerContentCoding.string(overridable)), return a manualResolutions
        entry {"id":"M1","supersededBy":null}, or cite the id of a STRICTLY LATER author decision
        that actually contradicts or reverses that edit. New detail on another topic replaces
        nothing. Equal or missing sequence cannot establish an override. Do not invent one to
        excuse a candidate that ignores an edit.
        A superseded manual replacement is no longer required in CHECKLIST (sentence may be null).
        A superseded deletion in REMOVED BY THE AUTHOR no longer forbids the authorized restoration.
        Cite a superseded replacement's ID in sentence refs only if the sentence wrongly restores
        that old decision as current, never as support for the replacing decision.
        """
        let resolutionExample = (overridable.isEmpty ? "" : ",\"manualResolutions\":["
            + overridable.map { "{\"id\":\"\($0)\",\"supersededBy\":null}" }.joined(separator: ",") + "]")
            + (replaceable.isEmpty ? "" : ",\"itemResolutions\":["
            + replaceable.map { "{\"id\":\"\($0)\",\"supersededBy\":null}" }.joined(separator: ",") + "]")
        // The template inventories the actual task, including manual edits.
        // It supplies no positive verdicts; all mappings still come from the
        // model and undergo the same exact-coverage and reference checks.
        let checklistTemplate = items.map { "{\"id\":\"\($0.id)\",\"sentence\":null}" }.joined(separator: ",")
        let sentencesTemplate = candidates.map {
            "{\"id\":\"\($0.id)\",\"kind\":\"courtesy|fact|position|refusal|question\",\"refs\":[]}"
        }.joined(separator: ",")
        // Laid out stable-first, so a later check resumes from the text it
        // shares instead of reading it again: the fixed rules (only the
        // author's name varies), then this email's people and passages (the
        // same for every draft of it checked against this brief), then what
        // this request and this draft add. Each piece ends with a blank line
        // and the next opens with a word, so its last token is the same
        // whatever follows it.
        let rules = """
        Check a draft email against the author's content checklist and the context it could draw on.

        CHECKLIST: every item must be expressed somewhere in the draft, in any wording or language.
        For each item give the ID of the one draft sentence that expresses it, or that carries its
        main point when the item spans several draft sentences, or null if the draft does not
        express it. An item that only tells the writer how to write (tone, warmth, length,
        formality, wording) and asks the email to state nothing gets "sentence":"style". A qualifier (a time zone, duration, date, alternative, condition, unit or
        exception) counts only if the draft actually states it. Information that exists only in
        the checklist or context does not count.

        SENTENCES: classify each draft sentence.
        kind "courtesy": greeting, thanks, acknowledgment ("noted", "understood", "I understand", "glad to hear it", "sorry to hear that", "承知しました"), pleasantry or sign-off, with no commitment and no new information.
        kind "fact": states information about the situation, the world, or another person's actions or plans.
        kind "position": states what the author will do, can do, did, has done, wants, decides, offers, requests, promises, prefers, thinks, or is available for.
        kind "refusal": states what the author will not do, cannot do, declines, is unable to do, or apologizes for.
        kind "question": asks the recipient a question or asks them for information.
        refs: the checklist item IDs, prohibition IDs, removed IDs, superseded IDs, undecided IDs and context passage IDs whose content the sentence expresses (empty for courtesy).
        Before citing a source, resolve the people in BOTH texts. In a source, I/my means its from
        and you/your means its to. In the outgoing draft, I/my means \(authorName), and you/your
        means the outgoing recipient. The same wording may therefore describe DIFFERENT people.
        Cite a passage ONLY if it supports the same person doing, receiving or being permitted the
        same thing, with the same conditions. Topic overlap is not support. Something another
        person said they did, will do or want is never support for the author doing it.
        Every substantive clause must be supported: supporting one clause does not justify extra
        promises or assertions in the same sentence. Use refs:[] when any clause is unsupported.
        A position or refusal must be supported by a checklist item or by the author's earlier
        message in this conversation saying the same thing; support only from another person's
        message, or from another conversation, does not authorize it.
        A question must carry a checklist item or ask the recipient about an undecided question.
        A fact must be supported by a checklist item or a passage; a fact with no support is unsupported.

        OVERSTATES: compare each draft sentence with the checklist items and the author's messages
        it relies on. A sentence overstates when it makes the author's agreement, interest,
        enthusiasm, praise, expertise or commitment stronger or broader than they say (the item
        says it aligns; the sentence says it resonates deeply, is particularly compelling, or
        describes the author's own research as matching), or adds to what an item says a detail,
        condition, reason or instruction the item does not give (the item says the plan needs
        another look; the sentence says to cut its budget by half). Restating a decision at
        the same strength, a courtesy, or a plain fact does not overstate. List only the overstating IDs.

        PROMISES: list the IDs of draft sentences in which the author promises, offers, volunteers
        or announces something they will do, arrange, send or take on ("I'll send the minutes
        tomorrow", "Je m'occupe de la réservation", "Ich kann die Vertretung übernehmen", "資料は私が
        用意します"). What another person will do, what the author did, thinks or asks, and a
        courtesy are not promises.

        CREDITS: list the IDs of draft sentences that thank or credit the recipient for advice, a
        suggestion, a proposal or guidance that, by the context, the author gave them: their
        message thanks the author for it, or the author's earlier message gave it ("Thank you for
        your advice" when they thanked the author for the advice; "Wie von Ihnen vorgeschlagen"
        for the author's own proposal). Thanks for what the recipient did, sent or proposed
        themselves is not listed.
        """
        let context = """
        The author is \(authorName), writing to \(request.content.to.joined(separator: ", ")).
        CONTEXT PASSAGES: \(try ComposerContentCoding.string(passages))
        """
        let sections = [prohibitionSection, removedSection, supersededSection, undecidedSection, historySection,
                        itemResolutionSection, manualResolutionSection].filter { !$0.isEmpty }
        let answerForm = """
        Return one line of compact JSON with no line breaks. Fill this template for the actual
        IDs below; keep every entry, including every M entry. Replace sentence null with a draft
        sentence ID only when that sentence expresses the checklist item. Choose one kind per
        sentence and fill its refs from the evidence. An empty checklist must remain empty.
        RESPONSE TEMPLATE: {"checklist":[\(checklistTemplate)],"sentences":[\(sentencesTemplate)]\(resolutionExample),"overstates":[],"promises":[],"credits":[]}

        CHECKLIST: \(try ComposerContentCoding.string(items))
        DRAFT SENTENCES: \(try ComposerContentCoding.string(candidates))
        """
        let prompt = PrefixCachedPrompt(cacheKey: "composer-check",
            checkpoints: [.init(rules + "\n\n", reuse: .instructions), .init(context + "\n\n", reuse: .item)],
            suffix: (sections.isEmpty ? "" : sections.joined(separator: "\n") + "\n\n") + answerForm)
        let itemIDs = items.map(\.id)
        let candidateIDs = candidates.map(\.id)
        let supportIDs = Set(itemIDs + prohibited.map(\.id) + removed.map(\.id)
            + replaced.map(\.id) + open.map(\.id) + passages.map(\.id))
        // One check: a response that breaks the protocol is not asked again.
        // The draft then goes out with the deterministic checks alone.
        let limit = answerTokens(checklistCount: items.count, sentenceCount: candidates.count)
            + (overridable.count + replaceable.count) * 24
        let result = try await generate(prompt, .auditor, limit)
        guard result.completed else { throw ComposerContentError.incomplete("The draft check did not finish.") }
        let response: Response
        do { response = try ComposerContentCoding.decodeModelObject(Response.self, from: result.text) }
        catch {
            guard let mended = Self.mendedAnswer(result.text),
                  let read = try? ComposerContentCoding.decodeModelObject(Response.self, from: mended) else {
                throw ComposerContentError.invalidAudit("The draft check did not return one complete structured result.")
            }
            response = read
        }
        // Each item and sentence is read once. An item the check left out,
        // answered twice differently, or matched to a sentence the draft does
        // not have is unread: neither required nor waived. A sentence it left
        // out or judged twice differently is not judged. Neither throws the
        // check away: one bad entry must not leave every other sentence
        // unchecked. A check that judged no sentence at all is no check.
        var mapped: [String: String?] = [:]
        var unread = Set<String>()
        for id in itemIDs {
            let answers = response.checklist.filter { $0.id == id }.map(\.sentence)
            guard let answer = answers.first, answers.allSatisfy({ $0 == answer }) else { unread.insert(id); continue }
            // A manual change is the author's own words, never a direction.
            if let sentence = answer, !candidateIDs.contains(sentence),
               sentence != Self.styleMarker || id.hasPrefix("M") {
                unread.insert(id)
                continue
            }
            mapped[id] = answer
        }
        var judged: [String: Response.Sentence] = [:]
        for id in candidateIDs {
            let entries = response.sentences.filter { $0.id == id }
            guard let entry = entries.first,
                  entries.allSatisfy({ $0.kind == entry.kind && ($0.refs ?? []) == (entry.refs ?? []) }) else {
                unread.insert(id)
                continue
            }
            judged[id] = entry
        }
        guard !judged.isEmpty else {
            throw ComposerContentError.invalidAudit("The draft check judged no sentence of the draft.")
        }
        let overstating = Set((response.overstates?.ids ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }).intersection(candidateIDs)
        let promising = Set((response.promises?.ids ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }).intersection(candidateIDs)
        let crediting = Set((response.credits?.ids ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }).intersection(candidateIDs)
        // How-to-write items are directions, honored by the writing, never stated.
        let styleItems = Set(mapped.filter { $0.value == Self.styleMarker && !$0.key.hasPrefix("M") }.map(\.key))
        let itemRequirement = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.requirementID) })
        let manual = Self.resolve(response.manualResolutions, ids: overridable) {
            request.content.isLaterAuthorDecision($1, than: $0)
        }
        let earlier = Self.resolve(response.itemResolutions, ids: replaceable) { id, replacing in
            itemRequirement[id].map { request.content.isLaterAuthorDecision(replacing, than: $0) } ?? false
        }
        let undecidedOrder = manual.unresolved.union(earlier.unresolved)
        let unresolved = undecidedOrder.union(unread)
        // A withdrawn deletion supports nothing, like an ID the check made up.
        let liftedDeletions = manual.superseded.intersection(removed.map(\.id))
        let itemText = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.text) })
        let prohibitionText = Dictionary(uniqueKeysWithValues: prohibited.map { ($0.id, $0.text) })
        let prohibitionRequirement = Dictionary(uniqueKeysWithValues: prohibited.map { ($0.id, $0.requirementID) })
        let undecidedText = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0.text) })
        let overridden = manual.superseded.union(earlier.superseded)
        // The deterministic manual-edit rule stands whatever the check left
        // unread; only an edit a later decision may have replaced is spared.
        findings.append(contentsOf: manualEditFindings(request: request, body: body,
            excluding: overridden.union(undecidedOrder)))
        let removedText = Dictionary(uniqueKeysWithValues: removed
            .filter { !overridden.contains($0.id) && !unresolved.contains($0.id) }.map { ($0.id, $0.text) })
        var supersededText = Dictionary(uniqueKeysWithValues: replaced.map { ($0.id, $0.text) })
        var supersededRequirement = Dictionary(uniqueKeysWithValues: replaced.map { ($0.id, $0.requirementID) })
        for item in items where overridden.contains(item.id) {
            supersededText[item.id] = item.text
            supersededRequirement[item.id] = item.requirementID
        }
        // A sentence of the author's earlier answer their Yes keeps is theirs
        // word for word, restored as written when the draft lacks it. When
        // the check gives several parts of that answer to one sentence that
        // says one of them and not another ("They are minor and appropriate,
        // and thank you" for "Yes, I approve both sets of corrections" too),
        // the other is not in the draft, and so is a part given to what the
        // check read as a courtesy. A sentence given one part alone is the
        // check's reading: rewording, another language or a two-word answer
        // ("Approved.") need not repeat its words.
        let draftText = Dictionary(candidates.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let requirementByID = Dictionary(request.content.requirements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        /// The author's words of a part of an earlier answer they kept.
        func keptWords(_ id: String) -> String? {
            guard let text = itemText[id], let requirement = itemRequirement[id].flatMap({ requirementByID[$0] }),
                  requirement.origin == .interviewAnswer,
                  let earlier = requirement.questionText.flatMap(ComposerInterviewPlanner.quotedEarlierAnswer) else { return nil }
            let words = Self.authorsWords(text)
            return Self.flattened(earlier).contains(Self.flattened(words)) ? words : nil
        }
        func keptAnswerMissing(_ id: String, in sentenceID: String) -> Bool {
            guard let sentence = draftText[sentenceID], let words = keptWords(id),
                  !ComposerDraftEvidence.holdsMostOf(sentence, words) else { return false }
            // A sentence the check itself read as a courtesy ("Thank you for
            // sending the corrections") says no answer of theirs, whatever
            // words it shares with one: their words go back beside it.
            if judged[sentenceID]?.kind == .courtesy { return true }
            return itemIDs.contains { other in
                other != id && itemRequirement[other] == itemRequirement[id] && (mapped[other] ?? nil) == sentenceID
                    && keptWords(other).map { ComposerDraftEvidence.holdsMostOf(sentence, $0) } == true
            }
        }
        var checklist: [ChecklistResult] = []
        for id in itemIDs {
            var sentence = styleItems.contains(id) ? nil : (mapped[id] ?? nil)
            if let mappedTo = sentence, keptAnswerMissing(id, in: mappedTo) { sentence = nil }
            checklist.append(ChecklistResult(id: id, sentenceID: sentence, isDirection: styleItems.contains(id)))
            if sentence == nil, !styleItems.contains(id), !overridden.contains(id), !unresolved.contains(id) {
                findings.append(ComposerPublicationFinding(kind: id.hasPrefix("M") ? .manualEdit : .omission,
                    requirementIDs: [itemRequirement[id] ?? id], candidateQuote: nil,
                    explanation: "The draft does not express: “\(itemText[id] ?? id)”"))
            }
        }
        var sentences: [SentenceResult] = []
        let theirMail = ComposerDraftEvidence.otherPartyTexts(request.content)
        let authorWords = ComposerDraftEvidence.authoredTexts(request.content)
        // Passages that speak for the author: their own mail, their notes,
        // and a memory cleared for assertion that is about them (in the first
        // person or by name). Someone else's email the author added as a
        // source, or a memory about someone else, is not.
        let authorFirstName = authorName.split(separator: " ").first.map(String.init) ?? authorName
        let ownedIDs = Set(brief.passages.filter { passage in
            guard passage.role != .authorPrior else { return true }
            guard let source = evidence[passage.sourceID]?.source else { return false }
            if source.kind == .note || source.kind == .notesApp { return true }
            guard source.kind == .memory, source.memoryUsePolicy == AccountMemoryUsePolicy.assertableKnowledge else { return false }
            // The author's name as whole words ("Li" is not "Linda"); in an
            // unspaced script, where no word is whole, as written.
            if ComposerWriterTraining.containsCJK(authorName) {
                return Self.hasFirstPersonSubject(passage.text, languageID: request.content.languageID)
                    || passage.text.contains(authorName)
            }
            let words = Set(passage.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let nameWords = authorName.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return Self.hasFirstPersonSubject(passage.text, languageID: request.content.languageID)
                || (!nameWords.isEmpty && nameWords.allSatisfy(words.contains))
                || (authorFirstName.count >= 3 && words.contains(authorFirstName.lowercased()))
        }.map(\.id))
        var copiedSelf = Set<String>()
        // Sentences the wording rule removed: never every sentence of the
        // author's (`wording`).
        var reworded = Set<String>()
        let canonicalIDs = Dictionary(supportIDs.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let passageText = Dictionary(passages.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let itemsByRequirement = Dictionary(grouping: items.filter { !overridden.contains($0.id) }, by: \.requirementID)
            .mapValues { $0.map(\.id) }
        // What the author and the sources wrote, for brackets the author named.
        let givenTexts = (request.content.requirements.map(\.originalText)
            + ComposerDraftRepair.authorSentences(request).kept + request.content.allEvidence.map(\.exactText))
            .map { $0.lowercased() }
        // The sentences the author typed by editing, as they last left them.
        let authorsEditedSentences = ComposerDraftRepair.authorSentences(request).kept.map(ComposerDraftRepair.normalized)
        // Sentences an instruction of the author's carries, cited or mapped.
        let instructedSentences = Set(candidates.filter { candidate in
            let cited = (judged[candidate.id]?.refs ?? []).contains { raw in
                canonicalIDs[raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
                    .map { itemText[$0] != nil && !overridden.contains($0) } == true
            }
            return cited || checklist.contains {
                $0.sentenceID == candidate.id && itemText[$0.id] != nil && !overridden.contains($0.id)
            }
        }.map(\.id))
        let positions = Dictionary(candidates.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // What the author wrote, read once, when a sentence needs it.
        var wordingRead = false
        var wordingCache: ComposerDraftEvidence.Wording?
        func wording() -> ComposerDraftEvidence.Wording? {
            if !wordingRead {
                wordingCache = ComposerDraftEvidence.Wording(content: request.content, identity: passages[0].text)
                wordingRead = true
            }
            return wordingCache
        }
        // The same reading for a sentence that carries an answer, in a
        // thread the author has not written in yet.
        var carryingRead = false
        var carryingCache: ComposerDraftEvidence.Wording?
        func carrying() -> ComposerDraftEvidence.Wording? {
            if !carryingRead {
                carryingCache = wording() ?? ComposerDraftEvidence.Wording(content: request.content,
                    identity: passages[0].text, inAnyThread: true)
                carryingRead = true
            }
            return carryingCache
        }
        let restatements = ComposerDraftEvidence.Restatements(content: request.content)
        // Earlier answers the author withdrew by answering No to them.
        let withdrawnAnswers = request.content.requirements.compactMap { requirement -> String? in
            guard requirement.origin == .interviewAnswer, let question = requirement.questionText,
                  ComposerInterviewPlanner.withdrawals.contains(where: { requirement.originalText.hasPrefix($0) }) else { return nil }
            return ComposerInterviewPlanner.quotedEarlierAnswer(question)
        }
        let passageSource = Dictionary(brief.passages.map { ($0.id, $0.sourceID) }, uniquingKeysWith: { first, _ in first })
        for candidate in candidates {
            // The salutation names who the email is to and says nothing of
            // the author's: no list the check returns makes it a position.
            // One with a slot for a name nobody gave ("Dear [Name],", "［氏名］様、")
            // is never sent: a bracket in a salutation is a slot unless the
            // author or a source wrote it.
            if positions[candidate.id] == 0, ComposerBoilerplate.isGreeting(candidate.text) {
                let lowered = candidate.text.lowercased()
                let slots = Self.greetingSlot.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered))
                    .compactMap { Range($0.range, in: lowered).map { String(lowered[$0]) } }
                // Judged here, by rule, whatever the check's answer listed.
                unread.remove(candidate.id)
                let subject = request.content.subject.lowercased()
                if slots.allSatisfy({ slot in subject.contains(slot) || givenTexts.contains { $0.contains(slot) } }) {
                    sentences.append(SentenceResult(id: candidate.id, kind: .courtesy, references: []))
                } else {
                    sentences.append(SentenceResult(id: candidate.id, kind: .position, references: []))
                    findings.append(ComposerPublicationFinding(kind: .unauthorizedPosition, requirementIDs: [],
                        candidateQuote: candidate.text,
                        explanation: "This leaves a placeholder for something nobody gave: “\(candidate.text)”",
                        sentenceID: candidate.id))
                }
                continue
            }
            // A judgment of how well the recipient's work fits the author's
            // research, interests or program ("aligns well with my research
            // interests", "an excellent fit for the MSDS Program") is the
            // author's assessment, whatever kind the check gave it, read or
            // not: it stands only on an instruction of theirs, an earlier
            // message of theirs in this conversation that judges it, or a
            // sentence they typed. A question asks for a judgment rather than
            // making one; one attributed to someone else is theirs.
            // A placeholder the writer left for something nobody gave
            // ("His expertise in [insert specific expertise if known]") is
            // never sent.
            let cited = (judged[candidate.id]?.refs ?? []).flatMap { raw -> [String] in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return canonicalIDs[trimmed.lowercased()].map { [$0] } ?? itemsByRequirement[trimmed] ?? []
            }
            let plain = ComposerDraftRepair.normalized(candidate.text).lowercased()
            let instructedHere = cited.contains { itemText[$0] != nil && !overridden.contains($0) }
                || checklist.contains { $0.sentenceID == candidate.id && itemText[$0.id] != nil && !overridden.contains($0.id) }
            let typedByAuthor = authorsEditedSentences.contains { $0.lowercased().contains(plain) }
            // A slot is spared only where the author or a source wrote that
            // very bracket (a button label they named); a slot the writer left
            // for a detail nobody gave goes, even in an instructed sentence.
            let slots = Self.placeholderSlots(in: candidate.text)
            if !slots.isEmpty, !slots.allSatisfy({ slot in givenTexts.contains { $0.contains(slot) } }) {
                sentences.append(SentenceResult(id: candidate.id, kind: .position, references: []))
                findings.append(ComposerPublicationFinding(kind: .unauthorizedPosition, requirementIDs: [],
                    candidateQuote: candidate.text,
                    explanation: "This leaves a placeholder for something nobody gave: “\(candidate.text)”",
                    sentenceID: candidate.id))
                continue
            }
            let asks = judged[candidate.id]?.kind == .question || candidate.text.hasSuffix("?") || candidate.text.hasSuffix("？")
            if !asks, Self.judgesFit(candidate.text) {
                let carried = instructedHere || typedByAuthor
                    || cited.contains { conversationIDs.contains($0) && passageText[$0].map(Self.judgesFit) == true }
                if !carried {
                    sentences.append(SentenceResult(id: candidate.id, kind: .position, references: []))
                    findings.append(ComposerPublicationFinding(kind: .unauthorizedPosition, requirementIDs: [],
                        candidateQuote: candidate.text,
                        explanation: "This judges how well their work fits the author's, which the author has not judged: “\(candidate.text)”",
                        sentenceID: candidate.id))
                    continue
                }
            }
            // Guidance the email being answered thanks the author for is the
            // author's; crediting the recipient with it turns it around.
            // An earlier answer the author said no longer stands, stated
            // again and not denied ("Ja, ich genehmige das Budget
            // weiterhin"), turns their No around.
            if !asks, !typedByAuthor, !withdrawnAnswers.isEmpty, judged[candidate.id]?.kind != .courtesy,
               withdrawnAnswers.contains(where: { earlier in
                   let language = request.content.languageID
                   let standing = ComposerDraftEvidence.saysStillStands(candidate.text, languageID: language)
                       && ComposerDraftEvidence.sharesKeyToken(candidate.text, earlier)
                   let named = ComposerDraftEvidence.namesEarlierAnswer(candidate.text, languageID: language)
                       && ComposerDraftEvidence.saysStillStands(candidate.text, languageID: language)
                   return ComposerDraftEvidence.saysAgain(candidate.text, earlier)
                       || ((standing || named) && ComposerDraftRepair.negates(candidate.text) != true)
               }) {
                sentences.append(SentenceResult(id: candidate.id, kind: .position, references: []))
                findings.append(ComposerPublicationFinding(kind: .unauthorizedPosition, requirementIDs: [],
                    candidateQuote: candidate.text,
                    explanation: "This states again an earlier answer the author said no longer stands: “\(candidate.text)”",
                    sentenceID: candidate.id))
                continue
            }
            // A question asks for guidance rather than crediting it; an
            // instruction of the author's or their typing is theirs.
            // The check lists thanks of any kind there; only thanks naming
            // guidance can credit it.
            let credits = (crediting.contains(candidate.id) && ComposerDraftEvidence.namesGuidance(candidate.text))
                || (request.content.anchor.map { $0.role == .incoming
                    && ComposerDraftEvidence.creditsBack(candidate.text, answering: ComposerContentPipeline.otherPartyText($0.passageText)) } ?? false)
            if credits, !typedByAuthor, !instructedHere, !asks, !ComposerReplySourcePolicy.isRequest(candidate.text) {
                sentences.append(SentenceResult(id: candidate.id, kind: .position, references: []))
                findings.append(ComposerPublicationFinding(kind: .unauthorizedPosition, requirementIDs: [],
                    candidateQuote: candidate.text,
                    explanation: "This credits them with guidance they thanked the author for: “\(candidate.text)”",
                    sentenceID: candidate.id))
                continue
            }
            guard let sentence = judged[candidate.id] else {
                // Not judged: only the deterministic evidence checks below read it.
                sentences.append(SentenceResult(id: candidate.id, kind: .fact, references: []))
                continue
            }
            // A reference is read the way the check plainly meant it: case and
            // spacing aside, or an instruction's ID for its checklist items. An
            // ID the check made up supports nothing; the sentence is judged on
            // the rest, rather than the whole check thrown away. When every ID
            // it cited is unreadable, the items the checklist says this
            // sentence expresses stand in; an empty list stays empty, because
            // that is how the check says a clause is unsupported.
            var references: [String] = []
            let counted = (sentence.refs ?? []).count >= Self.maximumSentenceReferences
            // The author speaking is never a fact a count supports: judged
            // as the author's position, on what the checklist says it carries.
            let speaksOnCount = counted && sentence.kind == .fact
                && Self.hasFirstPersonSubject(candidate.text, languageID: request.content.languageID)
            if counted, !speaksOnCount, sentence.kind == .fact {
                unread.insert(candidate.id)
                sentences.append(SentenceResult(id: candidate.id, kind: .fact, references: []))
                continue
            }
            if counted {
                references = checklist.filter { $0.sentenceID == candidate.id && !overridden.contains($0.id) }.map(\.id)
                if (sentence.refs ?? []).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "AUTHOR" }) {
                    references.append("AUTHOR")
                }
            } else {
                for raw in sentence.refs ?? [] {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = canonicalIDs[trimmed.lowercased()].map { [$0] } ?? itemsByRequirement[trimmed] ?? []
                    for id in resolved where !liftedDeletions.contains(id) && !references.contains(id) { references.append(id) }
                }
                if references.isEmpty, !(sentence.refs ?? []).isEmpty {
                    references = checklist.filter { $0.sentenceID == candidate.id && !overridden.contains($0.id) }.map(\.id)
                }
            }
            // What the author says they did, do or are is the author's own
            // statement, never a fact another person's email can support:
            // "I am forwarding the errata" copied from the sender's message.
            // Read as a fact, it stands only on something the author owns. A
            // sentence copied from their mail stays theirs: the evidence check
            // below has it rephrased rather than removed.
            let ownsSupport = references.contains { $0 == "AUTHOR" || itemText[$0] != nil || ownedIDs.contains($0) }
            let unownedSelf = sentence.kind == .fact && !ownsSupport
                && Self.hasFirstPersonSubject(candidate.text, languageID: request.content.languageID)
            let copied = unownedSelf
                && ComposerDraftEvidence.copiedSpeaker(candidate.text, theirs: theirMail, authored: authorWords) != nil
            if copied { copiedSelf.insert(candidate.id) }
            let kind: SentenceResult.Kind = unownedSelf && !copied ? .position : sentence.kind
            sentences.append(SentenceResult(id: candidate.id, kind: kind, references: references))
            if kind == .courtesy { continue }
            // Saying again what the author's earlier email in this
            // conversation already told everyone on this reply, who have
            // answered since, is repetition. Only a statement the check
            // grounded in that email (and in no instruction of the author's)
            // can be one; it stays when another passage it cites adds to it,
            // or when an instruction, the reply plan or a newer email asks for
            // it again.
            // A "sentence" split off at an ordinal ("am 5. | Juni um 10 Uhr")
            // is half of one: removing it would leave the other half broken.
            let afterOrdinal = positions[candidate.id].map { $0 > 0
                && candidates[$0 - 1].text.range(of: #"\d\.$"#, options: .regularExpression) != nil } ?? false
            // What a kept earlier answer asked that their email shows done,
            // asked again, repeats the earlier email: never the author's to
            // say again, whatever else the sentence cites.
            // Only a sentence that asks, and asks for that again: thanks for
            // what they sent is not one. Asking for it with more beside it
            // ("at your earliest convenience", "by Friday", "the signed
            // version of your transcripts") asks for it again all the same,
            // and asks for what the author did not.
            // An instruction of the author's carrying it keeps it. Of the kept
            // answer whose request was done, only another of its requests
            // does, said in the sentence beyond the done one ("your
            // transcripts from your master's program").
            let keptRequirements = Set(brief.currentAtoms.filter { (request.doneEarlierRequests ?? []).contains($0.text) }
                .map(\.requirementID))
            let carriers = (cited + checklist.filter { $0.sentenceID == candidate.id }.map(\.id)).filter { id in
                itemText[id] != nil && !overridden.contains(id)
            }
            let carriedByOther = carriers.contains { !keptRequirements.contains(itemRequirement[$0] ?? "") }
            if !carriedByOther, !typedByAuthor,
               let done = request.doneEarlierRequests, asks || ComposerDraftEvidence.mayAsk(candidate.text) {
                let wording = carrying()
                // What a text names: its content words ("transcripts", "成績証明書")
                // and initialisms, however short ("CV"); with no reading of
                // its words, the words that carry it.
                func named(_ text: String) -> Set<String> {
                    guard let wording else { return ComposerDraftEvidence.contentTokens(text) }
                    return ComposerDraftEvidence.Wording.keys(text, in: wording.language, contentOnly: true,
                        wordClasses: wording.wordClasses).union(Self.initialisms(text))
                }
                // What a request asks for: its content words, or with none
                // its initialisms ("CV"); never "ASAP" beside "transcripts".
                func things(_ text: String) -> Set<String> {
                    guard let wording else { return ComposerDraftEvidence.contentTokens(text) }
                    let initials = Self.initialisms(text)
                    // An initialism tagged as a word ("ASAP") is one still.
                    let words = ComposerDraftEvidence.Wording.keys(text, in: wording.language, contentOnly: true,
                        wordClasses: wording.wordClasses).filter { key in
                            !initials.contains { $0 == key || ($0.count >= 6 && String($0.prefix(5)) == key) }
                        }
                    return words.isEmpty ? initials : words
                }
                let said = named(candidate.text)
                let askedAgain = done.contains { earlier in
                    let again = ComposerDraftEvidence.saysAgain(candidate.text, earlier)
                    let asked = things(earlier)
                    // Another request of the kept answer the sentence says, in
                    // a thing beyond the done one's ("could" is none), carries it.
                    let carriedByKept = carriers.contains { id in
                        let words = Self.authorsWords(itemText[id] ?? "")
                        return ComposerDraftEvidence.holdsMostOf(candidate.text, words)
                            && !named(words).subtracting(named(earlier)).isDisjoint(with: said)
                    }
                    // Nothing long enough to compare by ("the map"): said
                    // again, with every short word of it ("Please send me the
                    // key" is not "Please send me the map").
                    guard !asked.isEmpty else {
                        let short = Set(ComposerDraftEvidence.restatementTokens(earlier).filter { $0.count <= 3 })
                        return again && short.isSubset(of: Set(ComposerDraftEvidence.restatementTokens(candidate.text)))
                            && !carriedByKept
                    }
                    // Asked for by initialisms alone ("your CV ASAP"), any of them is it.
                    let byInitialisms = asked == Self.initialisms(earlier)
                    guard again || ComposerDraftEvidence.holdsMostOf(candidate.text, earlier),
                          byInitialisms ? !asked.isDisjoint(with: said) : asked.isSubset(of: said) else { return false }
                    return !carriedByKept
                }
                if askedAgain {
                    findings.append(ComposerPublicationFinding(kind: .repetition, requirementIDs: [],
                        candidateQuote: candidate.text,
                        explanation: "This asks again for what their email shows done: “\(candidate.text)”",
                        sentenceID: candidate.id))
                    continue
                }
            }
            if let restatements, !asks, !ComposerDraftEvidence.isQuestion(candidate.text), kind != .question,
               !instructedHere, !typedByAuthor, !afterOrdinal,
               candidate.text.range(of: #"\d\.$"#, options: .regularExpression) == nil,
               !references.contains(where: { itemText[$0] != nil }) {
                var earlier = Set<UUID>()
                var others: [String] = []
                for id in references {
                    if conversationIDs.contains(id), let source = passageSource[id], restatements.isRepeatable(source) {
                        earlier.insert(source)
                    } else if id != "AUTHOR", let text = passageText[id] {
                        // The author's identity supports a self-introduction,
                        // never a change of what they said.
                        others.append(text)
                    }
                }
                // A sentence their earlier email has word for word is that
                // email again, whatever the check cited.
                if earlier.isEmpty {
                    let tokens = ComposerDraftEvidence.restatementTokens(candidate.text)
                    earlier = Set(restatements.emails.filter { $0.value.sentences.contains(tokens) }.map(\.key))
                }
                if !earlier.isEmpty, restatements.restates(candidate.text, citing: earlier, alongside: others) {
                    findings.append(ComposerPublicationFinding(kind: .repetition, requirementIDs: [],
                        candidateQuote: candidate.text,
                        explanation: "This says again what the author already told them in an earlier email: “\(candidate.text)”",
                        sentenceID: candidate.id))
                    continue
                }
            }
            if overstating.contains(candidate.id), kind == .position || kind == .refusal || kind == .fact {
                findings.append(ComposerPublicationFinding(kind: .unauthorizedPosition, requirementIDs: [],
                    candidateQuote: candidate.text,
                    explanation: "This states the author's view more strongly than they gave it, or adds what they did not give: “\(candidate.text)”",
                    sentenceID: candidate.id))
                continue
            }
            func finding(_ kind: ComposerPublicationFinding.Kind, _ requirements: [String], _ explanation: String) {
                findings.append(ComposerPublicationFinding(kind: kind, requirementIDs: requirements,
                    candidateQuote: candidate.text, explanation: explanation, sentenceID: candidate.id))
            }
            let violated = references.filter { prohibitionText[$0] != nil }
            if let first = violated.first {
                finding(.prohibited, violated.compactMap { prohibitionRequirement[$0] },
                    "This states, promises, refuses or apologizes for something the instructions prohibit (“\(prohibitionText[first] ?? first)”): “\(candidate.text)”")
                continue
            }
            let restored = references.filter { removedText[$0] != nil }
            if let first = restored.first {
                finding(.manualEdit, restored,
                    "This restores wording the author removed (“\(removedText[first] ?? first)”): “\(candidate.text)”")
                continue
            }
            let stale = references.filter { supersededText[$0] != nil }
            if let first = stale.first {
                finding(.unauthorizedPosition, stale.compactMap { supersededRequirement[$0] },
                    "This asserts, as the author's current position, a decision a later instruction replaced (“\(supersededText[first] ?? first)”): “\(candidate.text)”")
                continue
            }
            // The author speaking on a passage a skipped question quotes
            // answers that question, whether or not the check cited it: "I do
            // not have data on that" for the question the author left open.
            let authorSpeaks = kind == .position || kind == .refusal
                || (kind == .fact && Self.hasFirstPersonSubject(candidate.text, languageID: request.content.languageID))
            // Any statement on a skipped question's request addresses it (the
            // author left it unanswered), however it is phrased: "the main
            // driver is likely …" answers it as surely as "I think …".
            let addresses = authorSpeaks || kind == .fact
            var decided = references.filter { undecidedText[$0] != nil }
            // Not when an instruction of the author's carries the sentence
            // (the answer they gave cites the passage it answers), nor on a
            // counted list, whose passages are a count.
            let instructed = references.contains { itemText[$0] != nil && !overridden.contains($0) }
            if decided.isEmpty, addresses, !instructed, !counted {
                let cited = (sentence.refs ?? []).compactMap {
                    canonicalIDs[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
                }
                decided = open.filter { item in
                    let question = Self.flattened(item.text)
                    let earlier = Self.earlierAnswerParts(item.text)
                    return cited.contains { id in
                        guard let text = passageText[id].map(Self.flattened), text.count >= 10 else { return false }
                        // A question on the author's earlier answer leaves that
                        // answer open: their request it quotes ties a sentence
                        // to it only when the sentence speaks to the answer
                        // ("the corrections are still approved"), not when it
                        // thanks them for what they sent.
                        if let earlier {
                            if Self.flattened(earlier.answer).contains(text) { return true }
                            return Self.flattened(earlier.request).contains(text)
                                && ComposerDraftEvidence.sharesKeyWord(candidate.text, earlier.answer)
                        }
                        return question.contains(text)
                    }
                }.map(\.id)
            }
            if kind == .question {
                // An ask is the author's only when an instruction of theirs
                // carries it (cited, or the checklist says so), or when it is
                // a short follow-up on the author's instructed sentence just
                // before it ("Does that work for you?"); any other is an ask
                // made on the author's behalf. Asking the recipient about a
                // question the author skipped or has not reached is one: the
                // author left it unanswered, not asked back ("Could you tell
                // me which days you mean?" for a meeting they skipped).
                let carried = instructed || checklist.contains {
                    $0.sentenceID == candidate.id && itemText[$0.id] != nil && !overridden.contains($0.id)
                }
                let candidateIndex = positions[candidate.id]
                let followsInstruction = candidate.text.count <= 80
                    && ComposerReplySourcePolicy.matchesBackReference(candidate.text)
                    && candidateIndex.map { $0 > 0 && instructedSentences.contains(candidates[$0 - 1].id) } == true
                if !carried, !followsInstruction {
                    finding(.unauthorizedPosition, [],
                        "This asks the recipient something the author has not asked: “\(candidate.text)”")
                }
                continue
            }
            if let first = decided.first, addresses {
                finding(.undecided, decided,
                    "This decides a question the author has not answered (“\(undecidedText[first] ?? first)”); leave it open: “\(candidate.text)”")
                continue
            }
            let checklistSupport = references.filter { itemText[$0] != nil && !overridden.contains($0) }
            let conversationSupport = references.filter { conversationIDs.contains($0) }
            // A promise is the author's only when a decision of theirs for this
            // reply makes it (an answer, an instruction) or they typed it. What
            // they suggested earlier, offered before, or what the other person
            // will do never commits them now: "I recommend raising it at the
            // meeting" does not become "I will put it on the agenda".
            // One a reconfirmed answer quotes from their earlier email is
            // theirs again (a reconfirmation's Yes is their earlier answer).
            let reconfirmed = references.contains { id in
                guard authorPriorIDs.contains(id), let text = passageText[id].map(Self.flattened), text.count >= 10 else { return false }
                return items.contains { !overridden.contains($0.id) && Self.flattened(Self.authorsWords($0.text)).contains(text) }
            }
            let promises = promising.contains(candidate.id)
                || (kind == .position && ComposerDraftEvidence.commitsAuthor(candidate.text, languageID: request.content.languageID))
            if promises, kind == .position || kind == .refusal, checklistSupport.isEmpty,
               !instructedHere, !typedByAuthor, !reconfirmed {
                finding(.unauthorizedPosition, [],
                    "This commits the author to something no answer or instruction of theirs decides: “\(candidate.text)”")
                continue
            }
            // A position that carries a number (a date, time, count) found in
            // a cited earlier message but in none of the current instructions
            // has fused an old statement into today's instructed answer.
            // Numbers the instructions contain are the author's current decision.
            let earlier = references.filter { authorPriorIDs.contains($0) }
            if !earlier.isEmpty, !checklistSupport.isEmpty, kind == .position,
               let leaked = Self.leakedNumber(in: candidate.text, instructions: request.content.requirements.map(\.originalText),
                   earlierTexts: earlier.compactMap { id in brief.passages.first { $0.id == id }?.text }) {
                finding(.unauthorizedPosition, [],
                    "This carries “\(leaked)” from the author's earlier message (\(earlier[0])) into a current position; only the current instructions decide the author's dates and availability: “\(candidate.text)”")
                continue
            }
            // The author speaking, authorized only by their earlier message,
            // must say what the author wrote, not something new nobody gave
            // ("I'd like to ask the registrar for support" is not "I
            // recommend raising it at the meeting"): the check cites that
            // message for whatever sits near it in the draft.
            // Half a sentence split at an ordinal ("am 5. | Juni"), in a
            // language that writes ordinals with a dot, is left whole.
            let ordinalSplit = Self.ordinalLanguages.contains(String(request.content.languageID.lowercased()
                .prefix { $0 != "-" && $0 != "_" }))
                && (afterOrdinal || candidate.text.range(of: #"\d\.$"#, options: .regularExpression) != nil)
            if authorSpeaks, checklistSupport.isEmpty, !instructedHere, !conversationSupport.isEmpty,
               !typedByAuthor, !ordinalSplit, let wording = wording() {
                let numbers = wording.unsuppliedNumbers(candidate.text)
                if !numbers.isEmpty || !wording.isAuthors(candidate.text) {
                    reworded.insert(candidate.id)
                    finding(.unauthorizedPosition, [], numbers.isEmpty
                        ? "This states a position the author's earlier messages do not give: “\(candidate.text)”"
                        : "This gives a number (“\(numbers[0])”) no one gave: “\(candidate.text)”")
                    continue
                }
            }
            // The checklist giving an instruction of the author's to a
            // sentence the check read as their position, in words of that
            // instruction, carries it, though its refs cite only the passages
            // it is about (the check often leaves the item out of refs). An
            // empty refs list still says a clause is unsupported.
            // Only a position (a refusal may turn the answer around), never
            // a promise, and only one whose words the wording rule finds
            // given: an extra clause nobody gave is not carried.
            // The author's No to a reconfirmation, in the writer's words, is
            // carried by reading as one ("My earlier approval no longer
            // stands"), whatever kind the check gave it.
            let given = carrying().map { $0.isAuthors(candidate.text) && $0.unsuppliedNumbers(candidate.text).isEmpty } == true
            let carriesNo = !references.isEmpty && given && !promising.contains(candidate.id)
                && ComposerDraftRepair.negates(candidate.text) == true
                && checklist.contains { item in
                    item.sentenceID == candidate.id && !overridden.contains(item.id)
                        && itemText[item.id].map { ComposerInterviewPlanner.withdrawals.contains(
                            Self.authorsWords($0).trimmingCharacters(in: .whitespacesAndNewlines)) } == true
                }
            // A bare answer ("Yes", "はい", "No") means what its question
            // asks: "I am in a Maasai village" carries Yes to “Are you in a
            // Maasai village?” by the words of that request, said the same
            // way round, a refusal only for a No.
            let carried = carriesNo || !references.isEmpty && !promising.contains(candidate.id)
                && given
                && checklist.contains { item in
                    guard item.sentenceID == candidate.id, !item.id.hasPrefix("M"), !overridden.contains(item.id),
                          let text = itemText[item.id], let wording = carrying() else { return false }
                    func keys(_ text: String) -> Set<String> {
                        ComposerDraftEvidence.Wording.keys(text, in: wording.language, contentOnly: true,
                            wordClasses: wording.wordClasses)
                    }
                    // A long word ("appropriate"), or a content word (a noun,
                    // a kanji or katakana word), in common.
                    func shares(_ words: String) -> Bool {
                        ComposerDraftEvidence.sharesKeyWord(candidate.text, words)
                            || !keys(candidate.text).isDisjoint(with: keys(words))
                    }
                    let words = Self.authorsWords(text)
                    if sentence.kind == .position, shares(words) { return true }
                    guard let question = Self.askedOfAuthor(text), keys(words).isEmpty,
                          !ComposerDraftEvidence.sharesKeyWord(words, words), !words.contains(where: \.isNumber) else { return false }
                    // A lone label reads as no language: No is the app's own.
                    let label = words.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
                    let no = ComposerInterviewPlanner.reconfirmationLanguages.contains {
                        ComposerInterviewPlanner.noLabel($0).lowercased() == label
                    } || ComposerDraftRepair.negates(words) == true
                    guard kind == .position || (no && kind == .refusal),
                          (ComposerDraftRepair.negates(candidate.text) == true) == no else { return false }
                    return shares(ComposerInterviewPlanner.quotedEarlierAnswer(question) ?? question)
                }
            switch kind {
            case .position where checklistSupport.isEmpty && conversationSupport.isEmpty && !carried:
                finding(.unauthorizedPosition, [],
                    "This states a position, commitment or availability the author has not given: “\(candidate.text)”")
            case .refusal where checklistSupport.isEmpty && conversationSupport.isEmpty && !carried:
                finding(.unauthorizedPosition, [],
                    "This announces a refusal, inability or apology the author has not given: “\(candidate.text)”")
            case .fact where references.isEmpty:
                finding(.unsupportedClaim, [],
                    "Neither the instructions nor the supplied context supports this: “\(candidate.text)”")
            default:
                break
            }
        }
        // The deterministic evidence checks read every sentence the rules
        // above did not take, the reworded ones too: the guard below may give
        // those back.
        findings.append(contentsOf: ComposerDraftEvidence.findings(sentences: candidates,
            courtesy: Set(sentences.filter { $0.kind == .courtesy }.map(\.id)),
            flagged: Set(findings.filter { $0.sentenceID.map(reworded.contains) != true }.compactMap(\.sentenceID)),
            // A first-person sentence taken from their mail is read whole, as
            // the author's own statement would be, so it is rephrased.
            selfStatements: Set(sentences.filter { [.position, .refusal, .question].contains($0.kind) }.map(\.id))
                .union(copiedSelf),
            content: request.content))
        // The wording rule judges words, not meaning. Where it cannot tell
        // courtesy from content (a language without word classes, so every
        // word counts), it may take a genuine sentence for an invented one:
        // there it never takes every sentence the author said, and stands
        // down rather than leave nothing. A sentence another rule removes is
        // not one they said, except a repeat of their own earlier email.
        // Where it reads content, an invented sentence goes even if it is the
        // last, and a draft left with nothing of the author's that speaks of
        // the conversation (only thanks, a pleasantry, or nothing) is not
        // sent: the author is asked instead (`nothingLeft`).
        var nothingLeft: Bool?
        if !reworded.isEmpty, let wording = wording() {
            func isWordingFinding(_ finding: ComposerPublicationFinding) -> Bool {
                finding.kind == .unauthorizedPosition && finding.sentenceID.map(reworded.contains) == true
            }
            var removed = Set<String>(), repeated = Set<String>()
            for finding in findings where !isWordingFinding(finding)
                && !ComposerDraftRepair.rewrittenKinds.contains(finding.kind) {
                var ids = finding.sentenceID.map { [$0] } ?? []
                if ids.isEmpty, let quote = finding.candidateQuote?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !quote.isEmpty {
                    ids = candidates.filter {
                        ComposerContentText.occurrences(of: quote, in: $0.text) > 0
                            || ComposerContentText.occurrences(of: $0.text, in: quote) > 0
                    }.map(\.id)
                }
                if finding.kind == .repetition { repeated.formUnion(ids) } else { removed.formUnion(ids) }
            }
            let text = Dictionary(candidates.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
            // Read, not courtesy, not the rule's, and about the conversation.
            let speaking = sentences.filter { sentence in
                sentence.kind != .courtesy && !reworded.contains(sentence.id) && !unread.contains(sentence.id)
                    && !removed.contains(sentence.id) && wording.speaksOfTheConversation(text[sentence.id] ?? "")
            }
            if speaking.isEmpty, !wording.readsContent {
                findings.removeAll(where: isWordingFinding)
            } else {
                // A sentence that goes needs nothing else said of it.
                findings.removeAll { !isWordingFinding($0) && $0.sentenceID.map(reworded.contains) == true }
                nothingLeft = speaking.allSatisfy { repeated.contains($0.id) } ? true : nil
            }
        }
        // A draft that is mostly the author's earlier email written out again
        // word for word (half or more of what it says past courtesy, two
        // sentences at least) replays that email instead of answering this
        // one: a later ask sharing a word with a sentence of it ("would",
        // "timing") does not make that sentence asked for again. Every
        // sentence of it copied word for word goes, unless an answer,
        // instruction or edit of theirs carries or quotes it, or they typed
        // it.
        if let restatements {
            let earlier = Set(restatements.emails.values.flatMap(\.sentences))
            let kinds = Dictionary(sentences.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
            let carriedIDs = Set(checklist.compactMap(\.sentenceID))
                .union(sentences.filter { $0.references.contains { itemText[$0] != nil } }.map(\.id))
            let authorsWords = items.filter { !overridden.contains($0.id) }.map { Self.flattened(Self.authorsWords($0.text)) }
            let saying = candidates.filter { candidate in
                kinds[candidate.id] != .courtesy
                    && !(positions[candidate.id] == 0 && ComposerBoilerplate.isGreeting(candidate.text))
            }
            let copied = saying.filter { candidate in
                guard earlier.contains(ComposerDraftEvidence.restatementTokens(candidate.text)),
                      !carriedIDs.contains(candidate.id) else { return false }
                let plain = ComposerDraftRepair.normalized(candidate.text).lowercased()
                let flat = Self.flattened(candidate.text)
                return !authorsEditedSentences.contains { $0.lowercased().contains(plain) }
                    && !authorsWords.contains { $0.contains(flat) }
            }
            if copied.count >= Self.minimumReplayedSentences, copied.count * 2 >= saying.count {
                let flagged = Set(findings.compactMap(\.sentenceID))
                for candidate in copied where !flagged.contains(candidate.id) {
                    findings.append(ComposerPublicationFinding(kind: .repetition, requirementIDs: [],
                        candidateQuote: candidate.text,
                        explanation: "This draft writes the author's earlier email out again; this says again what they already told them: “\(candidate.text)”",
                        sentenceID: candidate.id))
                }
            }
        }
        // A draft that says mostly what the author never gave (half or more
        // of its sentences past the salutation decide, claim or commit what
        // no answer, instruction or email of theirs gives, or speak as the
        // other person) wrote beyond what it was given: what else it states
        // on its own account is not trusted either, the check having read it
        // beside all that. Its courtesies stay, its questions (the gate above
        // let through only those that carry an ask of the author's), and
        // whatever carries an answer, instruction or edit of theirs. Where
        // the wording rule cannot tell content from courtesy
        // (no word classes), its findings do not count as invention. Read
        // after that rule, so that what goes here never makes a draft look
        // empty of the author's words (`nothingLeft`) before the repair can
        // add an answer it left out.
        let invention: Set<ComposerPublicationFinding.Kind> = [.unauthorizedPosition, .unsupportedClaim, .undecided, .misattribution]
        let salutation = candidates.first.flatMap { ComposerBoilerplate.isGreeting($0.text) ? $0.id : nil }
        let draftBody = sentences.filter { $0.id != salutation }
        let bodyIDs = Set(draftBody.map(\.id))
        let wordsUnread = !reworded.isEmpty && (wording().map { !$0.readsContent } ?? false)
        let invented = Set(findings.filter { finding in
            invention.contains(finding.kind)
                && !(wordsUnread && finding.kind == .unauthorizedPosition && finding.sentenceID.map(reworded.contains) == true)
        }.compactMap(\.sentenceID)).intersection(bodyIDs)
        var swept = Set<String>()
        if draftBody.count >= Self.minimumSentencesForInventedDraft, invented.count * 2 >= draftBody.count {
            let flagged = Set(findings.compactMap(\.sentenceID))
            for sentence in draftBody where sentence.kind != .courtesy && !flagged.contains(sentence.id)
                && !checklist.contains(where: { $0.sentenceID == sentence.id })
                // What the wording rule gave back there, it could not judge.
                && !(wordsUnread && reworded.contains(sentence.id)) {
                let text = draftText[sentence.id] ?? ""
                // A question the gate let through, if it is one, or may be one
                // in a language the rules cannot read.
                if sentence.kind == .question, ComposerDraftEvidence.mayAsk(text) { continue }
                let plain = ComposerDraftRepair.normalized(text).lowercased()
                guard !authorsEditedSentences.contains(where: { $0.lowercased().contains(plain) }) else { continue }
                swept.insert(sentence.id)
                findings.append(ComposerPublicationFinding(kind: .unauthorizedPosition, requirementIDs: [],
                    candidateQuote: text,
                    explanation: "Most of this draft says what the author never gave; on its own account this is not theirs either: “\(text)”",
                    sentenceID: sentence.id))
            }
        }
        // A sentence that goes, taking an instruction it carried with it,
        // leaves that instruction unexpressed: the repair adds it back without
        // what made the sentence go. A rephrased sentence keeps its content.
        // An item a kept statement still expresses is not missing; a question
        // only concerns its item, and a courtesy expresses none.
        let going = Set(findings.filter { !ComposerDraftRepair.rewrittenKinds.contains($0.kind) }
            .compactMap(\.sentenceID))
        let stillExpressed = Set(sentences.filter { !going.contains($0.id) && [.position, .refusal, .fact].contains($0.kind) }
            .flatMap(\.references))
        for index in checklist.indices {
            let id = checklist[index].id
            guard let sentenceID = checklist[index].sentenceID, going.contains(sentenceID),
                  !overridden.contains(id), !unresolved.contains(id), !stillExpressed.contains(id) else { continue }
            checklist[index].sentenceID = nil
            findings.append(ComposerPublicationFinding(kind: id.hasPrefix("M") ? .manualEdit : .omission,
                requirementIDs: [itemRequirement[id] ?? id], candidateQuote: nil,
                explanation: "The draft does not express: “\(itemText[id] ?? id)”"))
        }
        // What the sweep took leaves thanks alone, with no answer or edit of
        // the author's for the repair to add: they are asked, as when the
        // wording rule leaves nothing. Where it reads no content, any
        // sentence left that is not courtesy speaks.
        if !swept.isEmpty, nothingLeft == nil,
           !findings.contains(where: { [.omission, .manualEdit].contains($0.kind) && $0.sentenceID == nil }) {
            let gone = Set(findings.filter { !ComposerDraftRepair.rewrittenKinds.contains($0.kind) }.compactMap(\.sentenceID))
            let reading = wording()
            let speaks = sentences.contains { sentence in
                sentence.kind != .courtesy && !gone.contains(sentence.id) && !unread.contains(sentence.id)
                    && (reading.map { !$0.readsContent || $0.speaksOfTheConversation(draftText[sentence.id] ?? "") } ?? true)
            }
            if !speaks { nothingLeft = true }
        }
        return Self(checklist: checklist, sentences: sentences, findings: findings,
                    unresolved: undecidedOrder.sorted(), unread: unread.sorted(), replaced: supersededText.values.sorted(),
                    nothingLeft: nothingLeft)
    }

    /// The check's answer on which earlier decisions a later one replaced.
    /// An ID it leaves out, answers twice differently, or says was replaced
    /// by a decision that is not strictly later is unresolved rather than a
    /// broken check: one unanswered entry must not leave every other
    /// sentence of the draft unchecked. "null" written as a string is null.
    private static func resolve(_ entries: [Response.ManualResolution]?, ids: [String],
                        isLater: (_ id: String, _ replacing: String) -> Bool)
        -> (superseded: Set<String>, unresolved: Set<String>) {
        var superseded: Set<String> = [], unresolved: Set<String> = []
        for id in ids {
            let answers = Set((entries ?? []).filter { $0.id == id }.map { entry in
                entry.supersededBy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { ["", "null", "none"].contains($0.lowercased()) ? nil : $0 }
            })
            guard answers.count == 1, let answer = answers.first else { unresolved.insert(id); continue }
            guard let replacing = answer else { continue }
            if isLater(id, replacing) { superseded.insert(id) } else { unresolved.insert(id) }
        }
        return (superseded, unresolved)
    }
}
