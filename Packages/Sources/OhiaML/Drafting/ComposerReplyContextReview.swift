import Foundation
import OhiaCore

/// Source resolutions produced with the initial question plan. The model selects
/// passage IDs; the app owns all quotations. Historical answers are evidence,
/// never new user choices.
public struct ComposerReplyContextReview: Codable, Sendable, Equatable {
    /// The most requests one reply links to settled answers.
    static let maximumResponseItems = 12
    /// Obligations of the reply, independent of the interview's user decisions.
    public struct ResponseItem: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            case supported, partial, missing, conflicting, decision
        }
        public let request: String
        public let answer: String
        public let status: Status
        public let evidence: [Citation]
        public var currentEvidence: [String]? = nil
        public var guidanceEvidence: [String]? = nil
    }
    public struct Citation: Codable, Sendable, Equatable {
        public let sourceID: UUID
        public let quote: String
        public var currentQuote: String? = nil
    }

    public struct Question: Codable, Sendable, Equatable {
        public enum Disposition: String, Codable, Sendable {
            case unresolved, answered, irrelevant
        }
        public let id: String
        public let disposition: Disposition
        public let reason: String
        public let anchorQuote: String?
        public let guidanceQuote: String?
        public let continuationNodeID: String?
        public let evidence: [Citation]
        /// For a question asking the author to stand by an earlier answer of
        /// theirs: that answer, quoted. Left open, it is what stays
        /// undecided, rather than the request it was asked about.
        public var earlierAnswer: String? = nil
    }

    public let purpose: String
    public let anchorQuote: String
    public let established: [Citation]
    public let questions: [Question]
    /// Set locally, never trusted from model output.
    public var contextFingerprint: String?
    public var subject: String?
    public var draftGuidance: String?
    /// Absence on an earlier prepared snapshot does not mean there are no requests.
    public var responseItems: [ResponseItem]?
    /// What each sentence of the email being answered asks of the author,
    /// as it was read before planning; set locally, never from the plan's
    /// model output. Nil when it was not read.
    public var incomingReading: ComposerIncomingReading?

    /// IDs belong to this exact input snapshot. The model selects passages;
    /// authored wording and attribution are always supplied by the app.
    struct Passage: Encodable {
        let id: String
        let role: String
        let sourceID: UUID?
        let label: String
        let text: String
    }

    struct Preparation: Decodable {
        struct Selection: Decodable { let id: String; let current: String? }
        struct Item: Decodable {
            let request: String
            let answer: String
            let status: ResponseItem.Status
            let evidence: [String]
        }
        struct Decision: Decodable {
            let id: String
            let disposition: Question.Disposition
            let reason: String
            let anchor: String?
            let guidance: String?
            let continuationNodeID: String?
            let evidence: [String]
            /// Set by the app, never read from model output.
            var earlierAnswer: String? = nil

            private enum CodingKeys: String, CodingKey {
                case id, disposition, reason, anchor, guidance, continuationNodeID, evidence
            }
        }
        let purpose: String
        let anchor: String?
        let established: [Selection]
        let responseItems: [Item]?
        let questions: [Decision]
    }

    static func passages(anchor: String, sources: [ComposerSource], guidance: String?, subject: String) -> [Passage] {
        func split(_ text: String, prefix: String, role: String, sourceID: UUID? = nil, label: String) -> [Passage] {
            var texts: [String] = []
            var start = text.startIndex
            var index = start
            var length = 0
            while index < text.endIndex {
                let character = text[index]
                let next = text.index(after: index)
                length += 1
                let sentenceEnd = "。！？?!".contains(character)
                    || (character == "." && (next == text.endIndex || text[next].isWhitespace))
                // Transport line wrapping is part of the authored sentence,
                // not a new passage boundary.
                if sentenceEnd || length >= 800 || next == text.endIndex {
                    let passage = String(text[start..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !passage.isEmpty { texts.append(passage) }
                    start = next
                    length = 0
                }
                index = next
            }
            return texts.enumerated().map { Passage(id: "\(prefix)-\($0.offset + 1)", role: role,
                sourceID: sourceID, label: label, text: $0.element) }
        }
        return split(subject, prefix: "subject", role: "current", label: "Current subject")
            + split(anchor, prefix: "current", role: "current", label: "Current message")
            + split(guidance ?? "", prefix: "guidance", role: "guidance", label: "Explicit user guidance")
            + sources.enumerated().flatMap { index, source in
                split(source.snippet, prefix: "source-\(index + 1)", role: source.kind.rawValue,
                    sourceID: source.id, label: source.label)
            }
    }

    static func passageJSON(anchor: String, sources: [ComposerSource], guidance: String?, subject: String) -> String {
        struct Text: Encodable { let id: String; let text: String }
        struct Group: Encodable { let role: String; let label: String; let passages: [Text] }
        let catalog = passages(anchor: anchor, sources: sources, guidance: guidance, subject: subject)
        func group(_ entries: [Passage]) -> Group? {
            guard let first = entries.first else { return nil }
            return Group(role: first.role, label: first.label, passages: entries.map { Text(id: $0.id, text: $0.text) })
        }
        // Keep the complete source wording, but encode source metadata once.
        // Short snapshot-local IDs resolve to the same exact stored quotations.
        let groups = ["Current subject", "Current message", "Explicit user guidance"].compactMap { label in
            group(catalog.filter { $0.sourceID == nil && $0.label == label })
        } + sources.compactMap { source in group(catalog.filter { $0.sourceID == source.id }) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(groups)) ?? Data("[]".utf8), as: UTF8.self)
    }

    // The interview repair response uses its own graph patch schema. Initial
    // reply preparation uses ComposerInterviewPlanner's flat items contract.
    static let preparationInstructions = """
    SOURCE-FIRST PREPARATION:
    Before creating any question, resolve EACH incoming request against the supplied source passages and explicit user guidance. A request answered there is settled: select its evidence and do not ask it again. Ask only the remaining material gaps. Never substitute a settled factual question for an unresolved author decision. If the sources supply logistics but not the user's participation, ask only about participation. If guidance already supplies a decision, even a conditional or negative decision, do not ask about it or solicit additional preferences.
    In context.purpose, briefly describe what the reply needs to address. In established, select exact historical passage IDs that resolve requested facts or materially clarify the current exchange. Context is available evidence, not a requirement to mention history in the draft. Keep only relevant passages; preserve speaker, dates and qualifications. Use explicit corrections over superseded facts. Never infer current consent, availability or completed actions from an older arrangement. Do not draft the email: the writer receives the whole incoming message, sources and author instructions.
    context contains purpose, anchor, established and questions. anchor is a current-message/subject passage ID. established contains {"id":"source-1-1","current":"current-1"} selections linking useful source facts to the current message. current may be null. Use only supplied IDs. context.questions describes each graph question: {"id":"q1","disposition":"unresolved","reason":"Specific missing information","anchor":"current-1","evidence":[]}. evidence contains source passage IDs, not prose. Do not include settled questions anywhere. A terminal graph has questions:[].
    """

    static func resolve(_ preparation: Preparation, anchor: String, sources: [ComposerSource], guidance: String?,
                        questions: [ComposerInterviewNode], subject: String) throws -> Self {
        let catalog = passages(anchor: anchor, sources: sources, guidance: guidance, subject: subject)
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func passage(_ id: String) throws -> Passage {
            guard let value = byID[id] else { throw failure("unknown passage ID \(id)") }
            return value
        }
        func current(_ id: String?, role: String) throws -> String? {
            guard let id else { return nil }
            let value = try passage(id)
            guard value.role == role, value.sourceID == nil else { throw failure("passage \(id) has the wrong authority") }
            return value.text
        }
        func citation(_ id: String) throws -> Citation {
            let value = try passage(id)
            guard let sourceID = value.sourceID, let source = sourcesByID[sourceID],
                  canSettleQuestion(source) else { throw failure("passage \(id) is not permitted answer evidence") }
            return Citation(sourceID: sourceID, quote: value.text)
        }
        let items = try (preparation.responseItems ?? []).map { item in
            guard let request = try current(item.request, role: "current") else { throw failure("missing request passage") }
            let entries = try item.evidence.map(passage)
            var result = ResponseItem(request: request, answer: item.answer, status: item.status,
                evidence: try entries.filter { $0.sourceID != nil }.map { try citation($0.id) })
            result.currentEvidence = entries.filter { $0.sourceID == nil && $0.role == "current" }.map(\.text)
            result.guidanceEvidence = entries.filter { $0.sourceID == nil && $0.role == "guidance" }.map(\.text)
            return result
        }
        let decisions = try preparation.questions.map { item in
            Question(id: item.id, disposition: item.disposition, reason: item.reason,
                anchorQuote: try current(item.anchor, role: "current"), guidanceQuote: try current(item.guidance, role: "guidance"),
                continuationNodeID: item.continuationNodeID, evidence: try item.evidence.map(citation),
                earlierAnswer: item.earlierAnswer)
        }
        let resolved = Self(purpose: preparation.purpose, anchorQuote: try current(preparation.anchor, role: "current") ?? "",
            established: try preparation.established.map {
                var selected = try citation($0.id)
                selected.currentQuote = try current($0.current, role: "current")
                return selected
            }, questions: decisions, responseItems: items)
        return try validated(String(decoding: JSONEncoder().encode(resolved), as: UTF8.self), anchor: anchor,
            sources: sources, guidance: guidance, questions: questions, subject: subject)
    }

    static func fingerprint(anchor: String, sources: [ComposerSource], subject: String = "") -> String {
        DraftReasoningContextFingerprint.value(for:
            subject + "\u{1f}" + anchor + "\u{1f}" + sources.map { $0.id.uuidString }.joined(separator: ",")
                + "\u{1f}" + sources.promptDigest()
        )
    }

    static func validated(
        _ raw: String,
        anchor: String,
        sources: [ComposerSource],
        guidance: String?,
        questions: [ComposerInterviewNode],
        subject: String = ""
    ) throws -> Self {
        guard raw.utf8.count <= 64 * 1_024 else { throw failure("response exceeds size limit") }
        var review: Self
        do {
            review = try JSONDecoder().decode(Self.self, from: Data(raw.utf8))
        } catch let DecodingError.keyNotFound(key, context) {
            throw failure("missing field \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.typeMismatch(_, context),
                    let DecodingError.valueNotFound(_, context),
                    let DecodingError.dataCorrupted(context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw failure("invalid review field \(path.isEmpty ? "root" : path): \(context.debugDescription)")
        } catch {
            throw failure("response does not match the review JSON schema")
        }
        guard !review.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("reply purpose is empty")
        }
        guard contains(review.anchorQuote, in: anchor) || contains(review.anchorQuote, in: subject)
                || (anchor.isEmpty && subject.isEmpty && review.anchorQuote.isEmpty) else {
            throw failure("current-email quotation is not verbatim")
        }
        guard review.questions.count == questions.count,
              Set(review.questions.map(\.id)) == Set(questions.map(\.id)) else {
            throw failure("question IDs are missing, duplicated, or unexpected")
        }
        let byID = sources.reduce(into: [UUID: ComposerSource]()) { $0[$1.id] = $1 }
        let nodesByID = questions.reduce(into: [String: ComposerInterviewNode]()) { $0[$1.id] = $1 }
        func validateCitation(_ citation: Citation) throws {
            guard let source = byID[citation.sourceID] else {
                throw failure("citation references an unknown source")
            }
            guard canSettleQuestion(source) else {
                throw failure("citation does not have authority to settle a question")
            }
            guard contains(citation.quote, in: source.snippet) else {
                throw failure("source quotation is not verbatim: “\(excerpt(citation.quote))”")
            }
            if let currentQuote = citation.currentQuote {
                guard contains(currentQuote, in: anchor) || contains(currentQuote, in: subject) else {
                    throw failure("linked current quotation is not verbatim")
                }
            }
        }
        try review.established.forEach(validateCitation)
        guard let items = review.responseItems else { throw failure("responseItems is required, including [] for an update without requests") }
        do {
            guard items.count <= maximumResponseItems else { throw failure("too many response items") }
            var requests = Set<String>()
            for item in items {
                guard contains(item.request, in: anchor) || contains(item.request, in: subject),
                      requests.insert(item.request.split(whereSeparator: \.isWhitespace).joined(separator: " ")).inserted,
                      !item.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw failure("response item has no unique current request or answer")
                }
                try item.evidence.forEach(validateCitation)
                if item.status == .supported || item.status == .partial || item.status == .conflicting {
                    guard !item.evidence.isEmpty || item.currentEvidence?.isEmpty == false
                        || item.guidanceEvidence?.isEmpty == false else { throw failure("response answer has no supporting evidence") }
                }
                if item.status == .conflicting {
                    guard item.evidence.count + (item.currentEvidence?.count ?? 0)
                        + (item.guidanceEvidence?.count ?? 0) >= 2 else { throw failure("conflict requires both evidence passages") }
                }
                for quote in item.currentEvidence ?? [] {
                    guard contains(quote, in: anchor) || contains(quote, in: subject) else {
                        throw failure("current evidence does not match its input")
                    }
                }
                for quote in item.guidanceEvidence ?? [] {
                    guard contains(quote, in: guidance ?? "") else { throw failure("guidance evidence does not match its input") }
                }
            }
        }
        for question in review.questions {
            guard !question.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw failure("question verdict has no reason")
            }
            try question.evidence.forEach(validateCitation)
            if let continuation = question.continuationNodeID {
                guard question.disposition == .answered,
                      nodesByID[question.id]?.outgoingNodeIDs.contains(continuation) == true else {
                    throw failure("answered question has an invalid continuation")
                }
            }
            switch question.disposition {
            case .unresolved:
                guard contains(question.anchorQuote, in: anchor)
                    || contains(question.anchorQuote, in: subject)
                    || contains(question.guidanceQuote, in: guidance ?? "") else {
                    throw failure("unresolved question has no current-email or guidance quotation")
                }
            case .answered:
                let hasCurrentAnswer = contains(question.anchorQuote, in: anchor)
                    || contains(question.anchorQuote, in: subject)
                if question.anchorQuote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                   !hasCurrentAnswer {
                    throw failure("answered question current-email quotation is not verbatim")
                }
                guard hasCurrentAnswer || contains(question.guidanceQuote, in: guidance ?? "") || !question.evidence.isEmpty else {
                    throw failure("answered question has no evidence")
                }
            case .irrelevant:
                break
            }
        }
        review.contextFingerprint = fingerprint(anchor: anchor, sources: sources, subject: subject)
        review.subject = subject
        review.draftGuidance = guidance
        return review
    }

    /// Rejected nodes follow their existing skip/convergence route. No answer
    /// or option is selected, and dependent-only branches become unreachable.
    func pruning(_ graph: ComposerInterviewProtocol) throws -> ComposerInterviewProtocol {
        let rejected = Set(questions.filter { $0.disposition != .unresolved }.map(\.id))
        let continuations = questions.reduce(into: [String: String]()) {
            $0[$1.id] = $1.continuationNodeID
        }
        let byID = graph.nodes.reduce(into: [String: ComposerInterviewNode]()) { $0[$1.id] = $1 }
        func route(_ id: String) throws -> String {
            var current = id
            var visited = Set<String>()
            while rejected.contains(current) {
                guard visited.insert(current).inserted,
                      let next = continuations[current] ?? byID[current]?.skipNextNodeID else { throw Self.failure }
                current = next
            }
            return current
        }
        let nodes = try graph.nodes.filter { !rejected.contains($0.id) }.map { node in
            ComposerInterviewNode(
                id: node.id, kind: node.kind, variableID: node.variableID,
                scope: node.scope, authority: node.authority, text: node.text,
                responseType: node.responseType,
                options: try node.options.map { option in
                    ComposerInterviewOption(
                        id: option.id, kind: option.kind, label: option.label,
                        detail: option.detail, nextNodeID: try route(option.nextNodeID),
                        draftEffects: option.draftEffects
                    )
                },
                answeredNextNodeID: try node.answeredNextNodeID.map(route),
                skipNextNodeID: try node.skipNextNodeID.map(route), impactWeight: node.impactWeight,
                // A rejected parent is never asked, so no pick could meet the
                // condition; the question is asked when reached rather than
                // silently dropped.
                condition: node.condition.flatMap { rejected.contains($0.nodeID) ? nil : $0 }
            )
        }
        let root = try route(graph.rootNodeID)
        let retained = nodes.reduce(into: [String: ComposerInterviewNode]()) { $0[$1.id] = $1 }
        var reachable = Set<String>()
        var pending = [root]
        while let id = pending.popLast() {
            guard reachable.insert(id).inserted else { continue }
            pending.append(contentsOf: retained[id]?.outgoingNodeIDs ?? [])
        }
        // A rejected parent must not silently erase a current independent or
        // still-needed conditional question. Inconsistent preparation fails.
        guard Set(questions.filter { $0.disposition == .unresolved }.map(\.id))
            .isSubset(of: reachable) else { throw Self.failure }
        return ComposerInterviewProtocol(
            rootNodeID: root, terminalNodeID: graph.terminalNodeID,
            nodes: nodes.filter { reachable.contains($0.id) }
        )
    }

    /// The review has already searched the complete pack. Keep its verified
    /// answer passages prominent instead of asking the writer to search it again.
    func draftingSources(anchor: String, sources: [ComposerSource], subject: String) -> [ComposerSource] {
        guard contextFingerprint == Self.fingerprint(anchor: anchor, sources: sources, subject: subject),
              let responseItems, !responseItems.isEmpty,
              responseItems.allSatisfy({ $0.status == .supported }) else { return sources }
        let citations = responseItems.flatMap(\.evidence) + established
        return sources.compactMap { source in
            // Preserve explicit notes and standing private instructions in full.
            if source.kind == .note || source.kind == .memory { return source }
            let quotes = citations.filter { $0.sourceID == source.id }.map(\.quote)
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            guard !quotes.isEmpty else { return source.isUserAdded ? source : nil }
            return ComposerSource(id: source.id, kind: source.kind, label: source.label,
                snippet: quotes.joined(separator: "\n"), messageID: source.messageID,
                filePath: source.filePath, isUserAdded: source.isUserAdded,
                addedAt: source.addedAt, provenance: source.provenance,
                authoredByUser: source.authoredByUser, authoredAt: source.authoredAt)
        }
    }

    /// The start of a rejected quotation, so a persistent failure names what
    /// the model wrote instead of only that it was wrong.
    private static func excerpt(_ quote: String?) -> String {
        let flat = (quote ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= 120 ? flat : String(flat.prefix(120)) + " [\(flat.count) characters]"
    }

    private static func contains(_ quote: String?, in text: String) -> Bool {
        guard let quote else { return false }
        // Email transport wraps authored lines; model quotations commonly
        // flatten those breaks. Preserve words and punctuation exactly while
        // comparing all whitespace runs as a single space.
        let normalizedQuote = quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedText = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !normalizedQuote.isEmpty && normalizedText.contains(normalizedQuote)
    }

    /// Memory authority is emitted by MemoryNoteRendering in the metadata
    /// header. Body text cannot grant itself authority, and the persisted use
    /// policy remains an independent requirement. Current transactional facts
    /// still require current evidence, as specified in the planner prompt.
    private static func canSettleQuestion(_ source: ComposerSource) -> Bool {
        guard source.kind != .threadState else { return false }
        guard source.kind == .memory else { return true }
        guard source.memoryUsePolicy == AccountMemoryUsePolicy.assertableKnowledge,
              source.snippet.hasPrefix("- ("), let end = source.snippet.range(of: ") ") else { return false }
        let tags = source.snippet[source.snippet.index(source.snippet.startIndex, offsetBy: 3)..<end.lowerBound]
            .components(separatedBy: ", ")
        return tags.contains("question-authority: settles-durable-question")
    }

    private static var failure: TrainingEngineError {
        .generationFailed("Reply context review did not provide complete, verifiable question evidence")
    }

    private static func failure(_ reason: String) -> TrainingEngineError {
        .generationFailed("Reply context review failed: \(reason)")
    }
}
