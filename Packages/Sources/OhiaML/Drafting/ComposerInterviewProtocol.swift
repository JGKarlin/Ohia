import Foundation

public enum ComposerInterviewPlanningOutcome: String, Codable, Sendable, Equatable {
    case planned
    case empty
    case invalid
}

public enum ComposerInterviewResponseType: String, Codable, Sendable, Equatable {
    case multipleChoice = "multiple_choice"
    case freeText = "free_text"
}

public enum ComposerInterviewScope: String, Codable, Sendable, Equatable {
    case approach
    case detail
}

public enum ComposerInterviewAuthority: String, Codable, Sendable, Equatable {
    case userDecision = "user_decision"
    case evidenceFact = "evidence_fact"
}

public enum ComposerInterviewFraming: String, Codable, Sendable, Equatable {
    case reply
    case compose
}

public enum ComposerInterviewNodeKind: String, Codable, Sendable, Equatable {
    case question
    case terminal
}

public enum ComposerInterviewOptionKind: String, Codable, Sendable, Equatable {
    case standard
    case otherUnanticipated = "other_unanticipated"
    /// A choice the author completes in their own words: a reconfirmation's
    /// No, then their answer now. Picking it needs words that say more than
    /// its label; unlike the open "Other", it is not what words meaning none
    /// of the choices stand for.
    case authorWords = "author_words"
    case unsureNeedToCheck = "unsure_need_to_check"
}

public struct ComposerInterviewOption: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let kind: ComposerInterviewOptionKind
    public let label: String
    public let detail: String?
    public let nextNodeID: String
    public let draftEffects: [String]

    public init(
        id: String,
        kind: ComposerInterviewOptionKind = .standard,
        label: String,
        detail: String? = nil,
        nextNodeID: String,
        draftEffects: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
        self.nextNodeID = nextNodeID
        self.draftEffects = draftEffects
    }

    /// Whether typed words fail to complete this choice: the open "Other"
    /// needs some, a choice in the author's words needs more than its label.
    public func needsMoreWords(than typed: String?) -> Bool {
        let words = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch kind {
        case .otherUnanticipated: return words.isEmpty
        case .authorWords: return words.isEmpty || ComposerInterviewDraftInputCompiler.namesOption(words, label)
        case .standard, .unsureNeedToCheck: return false
        }
    }
}

/// A question that matters only for some answers to an earlier question:
/// the date of an invitation the author may decline, say. It is asked only
/// when `nodeID` was answered with one of `optionIDs`. Otherwise it is passed
/// over along its skip route, and it is not an open decision for the draft.
public struct ComposerInterviewCondition: Codable, Sendable, Equatable {
    public let nodeID: String
    public let optionIDs: [String]

    public init(nodeID: String, optionIDs: [String]) {
        self.nodeID = nodeID
        self.optionIDs = optionIDs
    }
}

public struct ComposerInterviewNode: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let kind: ComposerInterviewNodeKind
    public let variableID: String?
    public let scope: ComposerInterviewScope?
    public let authority: ComposerInterviewAuthority?
    public let text: String?
    public let responseType: ComposerInterviewResponseType?
    public let options: [ComposerInterviewOption]
    public let answeredNextNodeID: String?
    public let skipNextNodeID: String?
    public let impactWeight: Double?
    /// Nil for a question asked whenever its route reaches it.
    public let condition: ComposerInterviewCondition?

    public static func question(
        id: String,
        variableID: String,
        scope: ComposerInterviewScope,
        authority: ComposerInterviewAuthority,
        text: String,
        responseType: ComposerInterviewResponseType,
        options: [ComposerInterviewOption] = [],
        answeredNextNodeID: String? = nil,
        skipNextNodeID: String,
        impactWeight: Double? = nil,
        condition: ComposerInterviewCondition? = nil
    ) -> ComposerInterviewNode {
        ComposerInterviewNode(
            id: id,
            kind: .question,
            variableID: variableID,
            scope: scope,
            authority: authority,
            text: text,
            responseType: responseType,
            options: options,
            answeredNextNodeID: answeredNextNodeID,
            skipNextNodeID: skipNextNodeID,
            impactWeight: impactWeight,
            condition: condition
        )
    }

    public static func terminal(id: String) -> ComposerInterviewNode {
        ComposerInterviewNode(
            id: id,
            kind: .terminal,
            variableID: nil,
            scope: nil,
            authority: nil,
            text: nil,
            responseType: nil,
            options: [],
            answeredNextNodeID: nil,
            skipNextNodeID: nil,
            impactWeight: nil,
            condition: nil
        )
    }

    public init(
        id: String,
        kind: ComposerInterviewNodeKind,
        variableID: String?,
        scope: ComposerInterviewScope?,
        authority: ComposerInterviewAuthority?,
        text: String?,
        responseType: ComposerInterviewResponseType?,
        options: [ComposerInterviewOption],
        answeredNextNodeID: String?,
        skipNextNodeID: String?,
        impactWeight: Double?,
        condition: ComposerInterviewCondition?
    ) {
        self.id = id
        self.kind = kind
        self.variableID = variableID
        self.scope = scope
        self.authority = authority
        self.text = text
        self.responseType = responseType
        self.options = options
        self.answeredNextNodeID = answeredNextNodeID
        self.skipNextNodeID = skipNextNodeID
        self.impactWeight = impactWeight
        self.condition = condition
    }

    public var outgoingNodeIDs: [String] {
        guard kind == .question else { return [] }
        var targets = options.map(\.nextNodeID)
        if let answeredNextNodeID {
            targets.append(answeredNextNodeID)
        }
        if let skipNextNodeID {
            targets.append(skipNextNodeID)
        }
        return targets
    }
}

public struct ComposerInterviewProtocol: Codable, Sendable, Equatable {
    public let rootNodeID: String
    public let terminalNodeID: String
    public var nodes: [ComposerInterviewNode]

    public init(
        rootNodeID: String,
        terminalNodeID: String,
        nodes: [ComposerInterviewNode]
    ) {
        self.rootNodeID = rootNodeID
        self.terminalNodeID = terminalNodeID
        self.nodes = nodes
    }

    public var questionNodes: [ComposerInterviewNode] {
        nodes.filter { $0.kind == .question }
    }
}

public enum ComposerInterviewRepairDisposition: Codable, Sendable, Equatable {
    case notRequired
    case pending(answerFingerprint: String)
    case unchanged(answerFingerprint: String)
    case applied(answerFingerprint: String, patchID: String)
    case failed(answerFingerprint: String)
}

/// How the one repair read an author's typed words on a choice question.
public struct ComposerInterviewTypedReading: Codable, Sendable, Equatable {
    /// The choice the typed words mean; nil when they mean none of the choices.
    public let optionID: String?

    public init(optionID: String?) {
        self.optionID = optionID
    }
}

public struct ComposerInterviewAnswer: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let nodeID: String
    public let selectedOptionID: String?
    public let freeText: String?
    public let skipped: Bool
    public let committedAt: Date
    public let answerFingerprint: String
    public let repairDisposition: ComposerInterviewRepairDisposition
    /// On a choice question, what the author's typed words mean, as the one
    /// repair read them. Typed words override the picked choice, so this, not
    /// `selectedOptionID`, decides the route and the questions that depend on
    /// the answer. Nil while the words are unread: before the repair, when it
    /// could not tell, and for answers saved before typed words were read.
    public let typedReading: ComposerInterviewTypedReading?

    public init(
        id: UUID = UUID(),
        nodeID: String,
        selectedOptionID: String? = nil,
        freeText: String? = nil,
        skipped: Bool,
        committedAt: Date = .now,
        answerFingerprint: String,
        repairDisposition: ComposerInterviewRepairDisposition,
        typedReading: ComposerInterviewTypedReading? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.selectedOptionID = selectedOptionID
        self.freeText = freeText
        self.skipped = skipped
        self.committedAt = committedAt
        self.answerFingerprint = answerFingerprint
        self.repairDisposition = repairDisposition
        self.typedReading = typedReading
    }

    private enum CodingKeys: String, CodingKey {
        case id, nodeID, selectedOptionID, freeText, skipped, committedAt
        case committedAtReferenceTime, answerFingerprint, repairDisposition, typedReading
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        nodeID = try values.decode(String.self, forKey: .nodeID)
        selectedOptionID = try values.decodeIfPresent(String.self, forKey: .selectedOptionID)
        freeText = try values.decodeIfPresent(String.self, forKey: .freeText)
        skipped = try values.decode(Bool.self, forKey: .skipped)
        if let precise = try values.decodeIfPresent(Double.self, forKey: .committedAtReferenceTime) {
            committedAt = Date(timeIntervalSinceReferenceDate: precise)
        } else {
            committedAt = try values.decode(Date.self, forKey: .committedAt)
        }
        answerFingerprint = try values.decode(String.self, forKey: .answerFingerprint)
        repairDisposition = try values.decode(ComposerInterviewRepairDisposition.self, forKey: .repairDisposition)
        // Absent from answers saved before typed words decided routing: their
        // words are unread, which leaves the choice open, never the pick's.
        typedReading = try values.decodeIfPresent(ComposerInterviewTypedReading.self, forKey: .typedReading)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(nodeID, forKey: .nodeID)
        try values.encodeIfPresent(selectedOptionID, forKey: .selectedOptionID)
        try values.encodeIfPresent(freeText, forKey: .freeText)
        try values.encode(skipped, forKey: .skipped)
        try values.encode(committedAt, forKey: .committedAt)
        // The interview's ISO date representation has whole-second precision.
        // Preserve the actual author-event time independently of the enclosing
        // encoder's date strategy, including when a Decisions version carries it.
        try values.encode(committedAt.timeIntervalSinceReferenceDate, forKey: .committedAtReferenceTime)
        try values.encode(answerFingerprint, forKey: .answerFingerprint)
        try values.encode(repairDisposition, forKey: .repairDisposition)
        try values.encodeIfPresent(typedReading, forKey: .typedReading)
    }

    /// This answer with the one repair's outcome recorded.
    func recordingRepair(
        _ disposition: ComposerInterviewRepairDisposition,
        typedReading: ComposerInterviewTypedReading?
    ) -> ComposerInterviewAnswer {
        ComposerInterviewAnswer(
            id: id,
            nodeID: nodeID,
            selectedOptionID: selectedOptionID,
            freeText: freeText,
            skipped: skipped,
            committedAt: committedAt,
            answerFingerprint: answerFingerprint,
            repairDisposition: disposition,
            typedReading: typedReading
        )
    }
}

public struct ComposerInterviewPatch: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let triggerNodeID: String
    public let triggerAnswerFingerprint: String
    public let replacedContinuationNodeID: String
    public let replacementEntryNodeID: String
    public var nodes: [ComposerInterviewNode]

    public init(
        id: String,
        triggerNodeID: String,
        triggerAnswerFingerprint: String,
        replacedContinuationNodeID: String,
        replacementEntryNodeID: String,
        nodes: [ComposerInterviewNode]
    ) {
        self.id = id
        self.triggerNodeID = triggerNodeID
        self.triggerAnswerFingerprint = triggerAnswerFingerprint
        self.replacedContinuationNodeID = replacedContinuationNodeID
        self.replacementEntryNodeID = replacementEntryNodeID
        self.nodes = nodes
    }
}

public struct ComposerInterviewPlan: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let contractVersion: Int
    public let inputFingerprint: String
    public let evidenceFingerprint: String
    public let generationEpoch: Int
    public let planningOutcome: ComposerInterviewPlanningOutcome
    public let baseProtocol: ComposerInterviewProtocol
    public let replyContext: ComposerReplyContextReview?
    /// The reading language the planner wrote the questions in
    /// (`SummarizationTargetLanguage.identifier`). Nil for a plan made before
    /// the language was recorded.
    public let questionLanguageIdentifier: String?

    public init(
        schemaVersion: Int,
        contractVersion: Int,
        inputFingerprint: String,
        evidenceFingerprint: String,
        generationEpoch: Int,
        planningOutcome: ComposerInterviewPlanningOutcome,
        baseProtocol: ComposerInterviewProtocol,
        replyContext: ComposerReplyContextReview? = nil,
        questionLanguageIdentifier: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.contractVersion = contractVersion
        self.inputFingerprint = inputFingerprint
        self.evidenceFingerprint = evidenceFingerprint
        self.generationEpoch = generationEpoch
        self.planningOutcome = planningOutcome
        self.baseProtocol = baseProtocol
        self.replyContext = replyContext
        self.questionLanguageIdentifier = questionLanguageIdentifier
    }
}

public struct ComposerInterviewState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let contractVersion: Int
    public let inputFingerprint: String
    public let evidenceFingerprint: String
    public let generationEpoch: Int
    public let planningOutcome: ComposerInterviewPlanningOutcome
    public let baseProtocol: ComposerInterviewProtocol
    public var acceptedPatches: [ComposerInterviewPatch]
    public var answers: [ComposerInterviewAnswer]
    public var groundings: [QuestionGrounding]
    public let replyContext: ComposerReplyContextReview?
    /// Accepted user instructions survive replacing the evidence-dependent graph.
    public var carriedDecisions: [ComposerInterviewAcceptedDecision]?
    /// The reading language the base questions were written in. Follow-up
    /// repairs write in it too, and an interview with unanswered questions
    /// in another language than the current setting needs a re-check.
    public let questionLanguageIdentifier: String?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        contractVersion: Int,
        inputFingerprint: String,
        evidenceFingerprint: String,
        generationEpoch: Int,
        planningOutcome: ComposerInterviewPlanningOutcome,
        baseProtocol: ComposerInterviewProtocol,
        acceptedPatches: [ComposerInterviewPatch] = [],
        answers: [ComposerInterviewAnswer] = [],
        groundings: [QuestionGrounding] = [],
        replyContext: ComposerReplyContextReview? = nil,
        carriedDecisions: [ComposerInterviewAcceptedDecision]? = nil,
        questionLanguageIdentifier: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.contractVersion = contractVersion
        self.inputFingerprint = inputFingerprint
        self.evidenceFingerprint = evidenceFingerprint
        self.generationEpoch = generationEpoch
        self.planningOutcome = planningOutcome
        self.baseProtocol = baseProtocol
        self.acceptedPatches = acceptedPatches
        self.answers = answers
        self.groundings = groundings
        self.replyContext = replyContext
        self.carriedDecisions = carriedDecisions
        self.questionLanguageIdentifier = questionLanguageIdentifier
    }

    public init(plan: ComposerInterviewPlan) {
        self.init(
            contractVersion: plan.contractVersion,
            inputFingerprint: plan.inputFingerprint,
            evidenceFingerprint: plan.evidenceFingerprint,
            generationEpoch: plan.generationEpoch,
            planningOutcome: plan.planningOutcome,
            baseProtocol: plan.baseProtocol,
            replyContext: plan.replyContext,
            questionLanguageIdentifier: plan.questionLanguageIdentifier
        )
    }

    /// True when a question is waiting to be answered in a language other
    /// than `readingLanguageIdentifier`. Answered interviews keep their
    /// questions; only an open question needs asking again.
    public func asksUnansweredQuestion(
        outsideReadingLanguage readingLanguageIdentifier: String
    ) -> Bool {
        guard let questionLanguageIdentifier,
              questionLanguageIdentifier != readingLanguageIdentifier else { return false }
        return ComposerInterviewExecutor.project(self).currentNode != nil
    }
}

public enum ComposerInterviewStateCoding {
    public static func decode(_ json: String?) -> ComposerInterviewState? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(ComposerInterviewState.self, from: data),
              state.schemaVersion == ComposerInterviewState.currentSchemaVersion else {
            return nil
        }
        return state
    }

    public static func encode(_ state: ComposerInterviewState?) -> String? {
        guard let state else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
