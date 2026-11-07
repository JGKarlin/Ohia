import Foundation
import OhiaCore

/// Builds the content brief. Passage indexing, boilerplate removal, role
/// labelling and relevance ranking are deterministic application work. One
/// short non-reasoning model call turns each instruction into verbatim,
/// typed checklist fragments and marks units a later instruction replaced;
/// anything the model returns that is not a verbatim fragment of its
/// instruction is discarded, a supersession mark that does not point at a
/// strictly later instruction is discarded, and every sentence of every
/// instruction the fragments leave partly uncovered is checked whole.
enum ComposerContentPreparer {
    static let atomAnswerTokens = 768

    struct Unit {
        var requirementID: String
        var text: String
        var kind: ComposerContentAtom.Kind = .content
        var supersededBy: String? = nil
    }

    private struct Response: Decodable {
        struct Unit: Decodable {
            let requirementID: String
            let text: String
            let kind: String?
            let supersededBy: String?

            private enum CodingKeys: String, CodingKey { case requirementID, text, kind, supersededBy }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                requirementID = try container.decode(String.self, forKey: .requirementID)
                text = try container.decode(String.self, forKey: .text)
                kind = try? container.decodeIfPresent(String.self, forKey: .kind)
                // A null, absent or non-string mark means "current".
                supersededBy = try? container.decodeIfPresent(String.self, forKey: .supersededBy)
            }
        }
        let units: [Unit]
    }

    static func prepare(_ input: ComposerContentInput, generate: ComposerModelCall) async throws -> ComposerContentBrief {
        try input.validate()
        let atoms = try await extractAtoms(input, generate: generate)
        let brief = ComposerContentBrief(contractVersion: ComposerContentBrief.currentVersion,
            contentIdentity: try ComposerContentIdentity.value(for: input), atoms: atoms,
            passages: rankedPassages(input), unknowns: input.unknowns)
        try brief.validate(against: input)
        return brief
    }

    // MARK: - Atoms

    /// The extraction's fixed rules: every extraction resumes from them.
    static let atomRules = """
        Extract the checklist of units from the author's instructions for an email.
        A unit is one fact, decision, answer, question to ask, offer, condition, qualifier
        (date, time, time zone, duration, place, amount, alternative, exception),
        prohibition, or writing direction. Copy each unit verbatim from its instruction
        text; never paraphrase, merge, reorder words, or add units that are not in the
        text. Keep the instruction's order. A qualifier inside a larger unit is ALSO its
        own unit, so it can be checked on its own: "Ask whether Monday or Tuesday, CET,
        works for a one-hour call" yields "Ask whether Monday or Tuesday", "CET" and
        "one-hour" as separate content units.
        kind "content": something the email must say, ask, confirm or state, or a qualifier of it,
        including a negative fact or position the author wants communicated ("but not the morning",
        "I have not contacted them yet", "no preference").
        kind "prohibition": an instruction to the writer not to say, promise, offer, commit to,
        imply, announce or apologize for something ("do not offer to organize", "do not promise a date").
        kind "direction": how to write (language, tone, voice, length, register, format), not what to say.
        The addressee named in a direction stays inside it: "Reply in Japanese to Professor Ito" is
        one direction, never a separate "to Professor Ito" unit.
        Entries have an id and sequence in the author's history. Extract units only from an
        entry's instruction, using its id as requirementID. A manualChange is an author edit:
        removed/replacement are the actual change; contextBefore locates it and
        replacementInContext widens a partial-word edit to its word. Unchanged context
        is not an instruction. Do not extract units
        from manualChange entries. They may replace an earlier instruction, however.
        When a STRICTLY LATER sequence replaces,
        withdraws or contradicts a unit (a changed date, a reversed decision, a lifted restriction),
        add "supersededBy" with that later entry's id to the unit; omit it otherwise.
        Missing sequence means unknown order and can never justify supersession.
        A later instruction that only adds detail, or an earlier one, replaces nothing.
        Return one line of compact JSON with no line breaks:
        {"units":[{"requirementID":"<id>","text":"<verbatim fragment>","kind":"content"},{"requirementID":"<id>","text":"<verbatim fragment>","kind":"content","supersededBy":"<later requirementID>"}]}
        INSTRUCTIONS:
        """

    static func atomPrompt(_ input: ComposerContentInput) throws -> PrefixCachedPrompt {
        PrefixCachedPrompt(cacheKey: "composer-atoms", checkpoints: [.init(atomRules, reuse: .instructions)],
            suffix: " " + (try ComposerContentCoding.string(input.authorHistory)))
    }

    static func extractAtoms(_ input: ComposerContentInput, generate: ComposerModelCall) async throws -> [ComposerContentAtom] {
        guard !input.requirements.isEmpty else { return [] }
        let result = try await generate(try atomPrompt(input), .preparer, atomAnswerTokens)
        guard result.completed else { throw ComposerContentError.incomplete("Checklist extraction ended before completing.") }
        let response: Response
        do { response = try ComposerContentCoding.decodeModelObject(Response.self, from: result.text) }
        catch { throw ComposerContentError.invalidBrief("Checklist extraction did not return one structured result.") }
        return atoms(from: response.units.map {
            Unit(requirementID: $0.requirementID, text: $0.text,
                 kind: $0.kind.flatMap(ComposerContentAtom.Kind.init(rawValue:)) ?? .content,
                 supersededBy: $0.supersededBy)
        }, input: input)
    }

    /// Verbatim-checked projection of the model's units, completed to full
    /// coverage. Pure so it can be tested without a model.
    static func atoms(from units: [Unit], input: ComposerContentInput) -> [ComposerContentAtom] {
        let requirements = Dictionary(uniqueKeysWithValues: input.requirements.map { ($0.id, $0) })
        var byRequirement: [String: [Unit]] = [:]
        var seen = Set<String>()
        for unit in units {
            guard let requirement = requirements[unit.requirementID] else { continue }
            let text = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = unit.requirementID + "|" + ComposerContentText.folded(text)
            guard !text.isEmpty, ComposerContentText.contains(requirement.originalText, fragment: text),
                  seen.insert(key).inserted,
                  (byRequirement[unit.requirementID]?.count ?? 0) < ComposerContentBrief.maximumAtomsPerRequirement
            else { continue }
            // Only a strictly later instruction can replace a unit; any other
            // mark is the model's error and the unit stays current.
            let later = unit.supersededBy.flatMap {
                input.isLaterAuthorDecision($0, than: requirement.id) ? $0 : nil
            }
            byRequirement[unit.requirementID, default: []].append(
                Unit(requirementID: unit.requirementID, text: text, kind: unit.kind, supersededBy: later))
        }
        var result: [ComposerContentAtom] = []
        for requirement in input.requirements.sorted(by: { $0.sequence < $1.sequence }) {
            var atoms: [ComposerContentAtom] = []
            var previous: ComposerContentAtom.Kind?
            for unit in byRequirement[requirement.id] ?? [] {
                let resolved = resolvedKind(unit.kind, text: unit.text, previous: previous, requirement: requirement.originalText)
                atoms.append(ComposerContentAtom(id: "", requirementID: requirement.id, text: unit.text,
                    kind: resolved, supersededBy: unit.supersededBy))
                previous = resolved
            }
            // Coverage. A fragment isolates a qualifier so it is checked on
            // its own; it never stands in for the sentence it came from. Any
            // sentence whose content terms the fragments do not all cover is
            // checked whole as well, so a partial extraction cannot drop an
            // obligation. The whole sentence is a direction only when every
            // fragment inside it is one and no clause the fragments left
            // alone reads as an obligation of its own ("Keep it short and
            // confirm Tuesday" is content; "Keep it short and warm" is a
            // direction), a prohibition only when it opens with the negative
            // imperative (or, in Japanese, closes with it) and no content
            // fragment sits inside it; a sentence whose negative clause comes
            // after content ("Confirm Tuesday without promising a room") is
            // content, and its prohibition fragment is still enforced on its
            // own. When a later instruction replaced a fragment, the sentence
            // is covered clause by clause: only the clause holding the
            // replaced fragment inherits its mark, and a clause the fragments
            // never touched ("and supply the projector") stays current.
            atoms.append(contentsOf: coverageAtoms(for: requirement, atoms: atoms))
            // An instruction with no content term at all is still an obligation.
            if atoms.isEmpty {
                atoms.append(ComposerContentAtom(id: "", requirementID: requirement.id, text: requirement.originalText, kind: .content))
            }
            result.append(contentsOf: atoms)
        }
        return result.enumerated().map { index, atom in
            var atom = atom
            atom.id = "A\(index + 1)"
            return atom
        }
    }

    /// The sentences of an instruction whose content terms are not all
    /// covered by the atoms lying inside them (or spanning them). Shared by
    /// the preparer, which completes the atom list, and brief validation,
    /// which rejects a brief that would let the check see less than the
    /// author wrote.
    static func uncoveredSentences(of instruction: String, atoms: [ComposerContentAtom]) -> [ComposerTextPassage] {
        ComposerTextPassage.index(instruction, prefix: "").filter { sentence in
            var coverage = SentenceCoverage(sentence.text)
            for atom in atoms { coverage.cover(atom.text) }
            return !coverage.isCovered
        }
    }

    /// The atoms that complete one requirement's coverage: one per sentence
    /// the fragments leave partly uncovered, or, where a fragment inside the
    /// sentence carries a supersession mark, one per uncovered clause.
    private static func coverageAtoms(for requirement: ComposerRequirement, atoms: [ComposerContentAtom]) -> [ComposerContentAtom] {
        var result: [ComposerContentAtom] = []
        for sentence in ComposerTextPassage.index(requirement.originalText, prefix: "") {
            var coverage = SentenceCoverage(sentence.text)
            var inside: [(atom: ComposerContentAtom, fragment: Int)] = []
            for atom in atoms {
                if let fragment = coverage.cover(atom.text) { inside.append((atom, fragment)) }
            }
            guard !coverage.isCovered else { continue }
            let kinds = Set(inside.map(\.atom.kind))
            // A clause the fragments never touched is an obligation of its
            // own, except a lone coordinated Latin word beside directions
            // ("and warm"), which is part of the direction. A lone CJK word
            // ("断る") is a predicate and stays an obligation.
            let allDirections = !inside.isEmpty && kinds == [.direction]
            func isObligation(_ clause: SentenceCoverage.Clause) -> Bool {
                !allDirections || clause.isFirst || coverage.termCount(in: clause) >= 2 || coverage.hasCJKTerm(in: clause)
            }
            func kind(_ kinds: Set<ComposerContentAtom.Kind>, obligations: [SentenceCoverage.Clause], text: String) -> ComposerContentAtom.Kind {
                if kinds == [.direction] {
                    if obligations.isEmpty { return .direction }
                    return obligations.allSatisfy { leadsWithNegativeImperative($0.text) } ? .prohibition : .content
                }
                if kinds.isSubset(of: [.prohibition]), leadsWithNegativeImperative(text) { return .prohibition }
                return .content
            }
            let clauses = coverage.clauses
            guard inside.contains(where: { $0.atom.supersededBy != nil }) else {
                let orphans = clauses.filter { !coverage.hasFragment(in: $0) && isObligation($0) }
                result.append(ComposerContentAtom(id: "", requirementID: requirement.id, text: sentence.text,
                    kind: kind(kinds, obligations: orphans, text: sentence.text)))
                continue
            }
            for clause in clauses where !coverage.isCovered(clause) {
                let touching = inside.filter { coverage.fragment($0.fragment, touches: clause) }.map(\.atom)
                if touching.isEmpty {
                    // A lone word coordinated with directions ("and warm") is
                    // part of the direction; it is still covered, as a current
                    // direction, so the brief validates.
                    let kind: ComposerContentAtom.Kind = !isObligation(clause) ? .direction
                        : leadsWithNegativeImperative(clause.text) ? .prohibition : .content
                    result.append(ComposerContentAtom(id: "", requirementID: requirement.id, text: clause.text, kind: kind))
                    continue
                }
                let marks = Set(touching.map(\.supersededBy))
                result.append(ComposerContentAtom(id: "", requirementID: requirement.id, text: clause.text,
                    kind: kind(Set(touching.map(\.kind)), obligations: [], text: clause.text),
                    supersededBy: marks.count == 1 ? touching[0].supersededBy : nil))
            }
        }
        return result
    }

    /// The negative imperative leads the sentence: within its first dozen
    /// characters in Latin script, or, for the sentence-final Japanese
    /// forms, anywhere. "Confirm Tuesday without promising a room" carries
    /// content before its negative clause and is not a prohibition sentence.
    static func leadsWithNegativeImperative(_ text: String) -> Bool {
        let normalized = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = negativeImperative.firstMatch(in: normalized, options: [], range: range) else { return false }
        if match.range(at: 4).location != NSNotFound { return true }
        return match.range.location <= 12
    }

    private static let negativeImperative = try! NSRegularExpression(
        pattern: #"(^|[^a-z])(do not|don't|dont|never|avoid|refrain from|without|must not|mustn't|should not|shouldn't|no need to|not to)([^a-z]|$)|(ないでください|しないで|しないよう|せず|ずに|ないよう|避け|禁止|不要|控え)"#,
        options: [.caseInsensitive])

    /// A prohibition is an instruction to the writer, so it reads as a negative
    /// imperative, or continues one inside the same sentence ("Do not take
    /// credit for booking the room or promise to circulate slides"). A negated
    /// fact or position the author wants communicated ("but not the morning")
    /// is content, whatever the model called it.
    static func resolvedKind(_ kind: ComposerContentAtom.Kind, text: String, previous: ComposerContentAtom.Kind?,
                             requirement: String) -> ComposerContentAtom.Kind {
        guard kind == .prohibition else { return kind }
        if isNegativeImperative(text) { return .prohibition }
        guard previous == .prohibition else { return .content }
        // A continuation must sit in a sentence that also holds a negative imperative.
        let sentence = ComposerTextPassage.index(requirement, prefix: "").first {
            ComposerContentText.contains($0.text, fragment: text)
        }
        guard let sentence else { return .content }
        return isNegativeImperative(sentence.text) ? .prohibition : .content
    }

    private static func isNegativeImperative(_ text: String) -> Bool {
        // Lowercase and width-normalize but keep spaces: the patterns are multi-word.
        let normalized = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).lowercased()
        let range = NSRange(normalized.startIndex..., in: normalized)
        return negativeImperative.firstMatch(in: normalized, options: [], range: range) != nil
    }

    // MARK: - Passages

    /// Function words the memory tokenizer keeps but that carry no relevance
    /// signal between an instruction and a passage. Numbers stay: dates matter.
    private static let ignoredTerms: Set<String> = [
        "and", "but", "not", "are", "was", "were", "has", "had", "its", "his", "her", "him", "she",
        "they", "them", "will", "just", "like", "very", "much", "more", "some", "any", "all", "one",
        "also", "been", "being", "than", "then", "too", "out", "off", "over", "own", "same", "such",
        "only", "other", "each", "few", "most", "both", "here", "there", "these", "those",
        "did", "let", "know", "get", "got", "ok"
    ]

    static func terms(_ text: String, maxTokens: Int) -> Set<String> {
        Set(AskMemoryTokenizer.tokenize(text, maxTokens: maxTokens).filter {
            !ignoredTerms.contains($0) && ($0.count > 2 || $0.allSatisfy(\.isNumber) || $0.contains(where: { $0.unicodeScalars.first.map { $0.value >= 0x3000 } == true }))
        })
    }

    static func rankedPassages(_ input: ComposerContentInput, preserveSelectedEvidence: Bool = false) -> [ComposerBriefPassage] {
        // Instruction terms describe what the author wants to say and count
        // double. Incoming-message terms describe what is being answered. The
        // thread subject is deliberately not a query: every message in a
        // thread matches its own title, so it cannot discriminate.
        var instructionTerms = Set<String>()
        for requirement in input.requirements {
            instructionTerms.formUnion(terms(requirement.originalText, maxTokens: 128))
        }
        var incomingTerms = Set<String>()
        if let anchor = input.anchor {
            incomingTerms = terms(anchor.passageText, maxTokens: 256).subtracting(instructionTerms)
        }
        func score(_ text: String) -> Int {
            let passageTerms = terms(text, maxTokens: 64)
            return 2 * passageTerms.intersection(instructionTerms).count + passageTerms.intersection(incomingTerms).count
        }
        var result: [ComposerBriefPassage] = []
        var candidates: [(order: Int, passage: ComposerBriefPassage)] = []
        for (index, evidence) in input.allEvidence.enumerated() where evidence.isSelectableEvidence {
            let texts: [String]
            if evidence.source.kind == .memory {
                // A note's conditions and limits stay attached to its claim.
                texts = [evidence.passageText]
            } else {
                texts = ComposerTextPassage.index(evidence.passageText, prefix: "").map(\.text)
            }
            for (offset, text) in texts.enumerated() {
                let passage = ComposerBriefPassage(id: "S\(index + 1):P\(offset + 1)", sourceID: evidence.source.id,
                    contentDigest: evidence.contentDigest, role: evidence.role, text: text, rank: 0,
                    score: score(text))
                if evidence.role == .incoming {
                    if preserveSelectedEvidence || result.count < ComposerContentBrief.maximumIncomingPassages { result.append(passage) }
                } else {
                    candidates.append((candidates.count, passage))
                }
            }
        }
        // A passage sharing no term with the instructions or the incoming
        // message is noise at every Length; it never enters the pool.
        let ranked = candidates.filter { preserveSelectedEvidence || $0.passage.score > 0 }.sorted {
            $0.passage.score == $1.passage.score ? $0.order < $1.order : $0.passage.score > $1.passage.score
        }.prefix(preserveSelectedEvidence ? candidates.count : ComposerContentBrief.maximumRankedPassages)
        for (offset, item) in ranked.enumerated() {
            var passage = item.passage
            passage.rank = offset + 1
            result.append(passage)
        }
        return result
    }
}

extension ComposerContentPreparer {
    /// Position-aware coverage of one sentence by verbatim fragments. The
    /// text is folded (case, width, quotes) one character to one character;
    /// fragments are matched with whitespace ignored, so a fragment the
    /// model spaced differently still lands on its characters. A term is
    /// covered only when every one of its characters is: two adjacent
    /// fragments cover the CJK bigram straddling their boundary, and a
    /// fragment cannot claim a word it only partly contains.
    ///
    /// Terms: every Latin word except a closed set of function words (an
    /// all-capital acronym such as "US" still counts), every number, a
    /// single capital letter that is not sentence-initial ("Room B"), and
    /// for CJK every adjacent pair with no hiragana in it (kanji, katakana,
    /// hangul, digits). Whole CJK runs, and any pair touching hiragana, are
    /// particles and inflection at a word's edge ("認す" in "確認する").
    struct SentenceCoverage {
        struct Clause {
            let text: String
            let range: Range<Int>
            let isFirst: Bool
        }

        private let original: [Character]
        private let folded: [Character]
        private let stripped: [Character]
        private let strippedOrigin: [Int]
        private let terms: [Range<Int>]
        private var covered: [Bool]
        private var fragments: [[Range<Int>]] = []

        init(_ text: String) {
            let original = Array(text)
            let folded = original.map(Self.fold)
            var stripped: [Character] = []
            var strippedOrigin: [Int] = []
            for (index, character) in folded.enumerated() where character != " " {
                stripped.append(character)
                strippedOrigin.append(index)
            }
            self.original = original
            self.folded = folded
            self.stripped = stripped
            self.strippedOrigin = strippedOrigin
            self.terms = Self.terms(folded: folded, original: original)
            self.covered = Array(repeating: false, count: folded.count)
        }

        /// Marks the fragment's characters covered wherever it occurs in the
        /// sentence, or the whole sentence when the fragment spans it, and
        /// returns the fragment's index; nil when it lies elsewhere. An
        /// occurrence that would split a Latin word or number ("10" inside
        /// "210", "at 3" inside "that 3") is not the fragment's place; CJK
        /// runs have no word boundaries and match anywhere.
        @discardableResult
        mutating func cover(_ fragment: String) -> Int? {
            let needle = Array(fragment).map(Self.fold).filter { $0 != " " }
            guard !needle.isEmpty else { return nil }
            var ranges: [Range<Int>] = []
            if needle.count >= stripped.count, !stripped.isEmpty, Self.occurrences(of: stripped, in: needle).isEmpty == false {
                ranges = [0..<folded.count]
            } else {
                ranges = Self.occurrences(of: needle, in: stripped).compactMap { start in
                    let lower = strippedOrigin[start], upper = strippedOrigin[start + needle.count - 1] + 1
                    if lower > 0, Self.isLatinWordCharacter(folded[lower - 1]), Self.isLatinWordCharacter(folded[lower]) { return nil }
                    if upper < folded.count, Self.isLatinWordCharacter(folded[upper]), Self.isLatinWordCharacter(folded[upper - 1]) { return nil }
                    return lower..<upper
                }
            }
            guard !ranges.isEmpty else { return nil }
            for range in ranges {
                for index in range { covered[index] = true }
            }
            fragments.append(ranges)
            return fragments.count - 1
        }

        var isCovered: Bool { terms.allSatisfy(isCovered) }

        func isCovered(_ clause: Clause) -> Bool {
            terms.filter { clause.range.contains($0.lowerBound) }.allSatisfy(isCovered)
        }

        func termCount(in clause: Clause) -> Int {
            terms.count { clause.range.contains($0.lowerBound) }
        }

        func hasCJKTerm(in clause: Clause) -> Bool {
            terms.contains { clause.range.contains($0.lowerBound) && $0.contains { Self.isCJK(folded[$0]) } }
        }

        func hasFragment(in clause: Clause) -> Bool {
            clause.range.contains { covered[$0] }
        }

        func fragment(_ index: Int, touches clause: Clause) -> Bool {
            fragments[index].contains { $0.overlaps(clause.range) }
        }

        /// The sentence split at commas, semicolons, colons, the ideographic
        /// comma and the Latin coordinators "and", "but" and "then". Only a
        /// span holding a term is a clause; its text is verbatim.
        var clauses: [Clause] {
            var result: [Clause] = []
            var start = 0
            func flush(_ end: Int) {
                var lower = start, upper = end
                while lower < upper, !(folded[lower].isLetter || folded[lower].isNumber) { lower += 1 }
                while upper > lower, folded[upper - 1] == " " { upper -= 1 }
                guard lower < upper, terms.contains(where: { (lower..<upper).contains($0.lowerBound) }) else { return }
                result.append(Clause(text: String(original[lower..<upper]), range: lower..<upper, isFirst: result.isEmpty))
            }
            var index = 0
            while index < folded.count {
                let character = folded[index]
                if Self.clauseSeparators.contains(character) {
                    flush(index)
                    start = index + 1
                    index += 1
                    continue
                }
                guard character.isLetter || character.isNumber else { index += 1; continue }
                var end = index
                while end < folded.count, folded[end].isLetter || folded[end].isNumber { end += 1 }
                if index > 0, end < folded.count, Self.coordinators.contains(String(folded[index..<end])) {
                    flush(index)
                    start = end
                }
                index = end
            }
            flush(folded.count)
            return result
        }

        // MARK: - Folding and terms

        private func isCovered(_ range: Range<Int>) -> Bool {
            range.allSatisfy { covered[$0] }
        }

        private static let clauseSeparators: Set<Character> = [",", ";", ":", "、"]
        private static let coordinators: Set<String> = ["and", "but", "then"]

        /// Articles, prepositions, conjunctions, pronouns, auxiliaries and
        /// contractions: not content at a fragment's edge. "am", "pm", "no",
        /// "not", "may" (a month) and "ok" stay content.
        private static let functionWords: Set<String> = [
            "a", "an", "the", "and", "or", "but", "so", "if", "as", "at", "by", "for", "from", "in", "into", "of",
            "on", "to", "with", "up", "it", "its", "is", "are", "be", "been", "was", "were", "do", "does", "did",
            "this", "that", "these", "those", "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his",
            "she", "her", "they", "them", "their", "who", "which", "what", "also", "too", "very", "just", "please",
            "would", "could", "should", "can", "will", "shall", "might", "must", "have", "has", "had", "than",
            "then", "there", "here", "about", "per", "via", "ll", "re", "ve"
        ]

        private static func fold(_ character: Character) -> Character {
            if character.isWhitespace || character.isNewline { return " " }
            var folded = character
            if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
               (0xFF01...0xFF5E).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value - 0xFEE0) {
                folded = Character(ascii)
            }
            folded = String(folded).lowercased().first ?? folded
            switch folded {
            case "‘", "’", "‚", "`", "´": return "'"
            case "“", "”", "„": return "\""
            case "–", "—", "‐", "‑": return "-"
            default: return folded
            }
        }

        private static func isCJK(_ character: Character) -> Bool {
            character.unicodeScalars.contains { scalar in
                scalar.value == 0x3005 || (0x3040...0x30FF).contains(scalar.value)
                    || (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                    || (0xF900...0xFAFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
                    || (0xFF66...0xFF9F).contains(scalar.value)
            }
        }

        private static func isHiragana(_ character: Character) -> Bool {
            character.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) }
        }

        private static func isLatinWordCharacter(_ character: Character) -> Bool {
            (character.isLetter || character.isNumber) && !isCJK(character)
        }

        /// A kanji, katakana or hangul character that forms no pair with
        /// either neighbour (a lone verb stem such as "断" in "断る", or
        /// "礼" in "お礼を") is a term on its own.
        private static func isLoneCJKContent(_ position: Int, in run: Range<Int>, folded: [Character]) -> Bool {
            let character = folded[position]
            guard isCJK(character), !isHiragana(character) else { return false }
            for neighbour in [position - 1, position + 1] where run.contains(neighbour) {
                if !isHiragana(folded[neighbour]) { return false }
            }
            return true
        }

        private static func terms(folded: [Character], original: [Character]) -> [Range<Int>] {
            var result: [Range<Int>] = []
            var index = 0
            var sentenceInitial = true
            while index < folded.count {
                guard folded[index].isLetter || folded[index].isNumber else { index += 1; continue }
                var end = index
                while end < folded.count, folded[end].isLetter || folded[end].isNumber { end += 1 }
                let run = index..<end
                if run.contains(where: { isCJK(folded[$0]) }) {
                    var sub = run.lowerBound
                    while sub < run.upperBound {
                        guard !isCJK(folded[sub]) else { sub += 1; continue }
                        var subEnd = sub
                        while subEnd < run.upperBound, !isCJK(folded[subEnd]) { subEnd += 1 }
                        if let word = wordTerm(sub..<subEnd, folded: folded, original: original,
                                               sentenceInitial: sentenceInitial && sub == run.lowerBound) {
                            result.append(word)
                        }
                        sub = subEnd
                    }
                    for position in run {
                        if isLoneCJKContent(position, in: run, folded: folded) {
                            result.append(position..<(position + 1))
                        }
                        guard position + 1 < run.upperBound else { continue }
                        let first = folded[position], second = folded[position + 1]
                        guard isCJK(first) || isCJK(second), !isHiragana(first), !isHiragana(second) else { continue }
                        result.append(position..<(position + 2))
                    }
                } else if let word = wordTerm(run, folded: folded, original: original, sentenceInitial: sentenceInitial) {
                    result.append(word)
                }
                sentenceInitial = false
                index = end
            }
            return result
        }

        private static func wordTerm(_ range: Range<Int>, folded: [Character], original: [Character],
                                     sentenceInitial: Bool) -> Range<Int>? {
            guard !range.isEmpty else { return nil }
            let word = String(folded[range])
            if word.count == 1 {
                if folded[range.lowerBound].isNumber { return range }
                guard !sentenceInitial, word != "i", original[range.lowerBound].isUppercase else { return nil }
                return range
            }
            if functionWords.contains(word) {
                guard original[range].allSatisfy(\.isUppercase) else { return nil }
            }
            return range
        }

        private static func occurrences(of needle: [Character], in haystack: [Character]) -> [Int] {
            guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
            var result: [Int] = []
            for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where haystack[start + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { result.append(start) }
            }
            return result
        }
    }
}
