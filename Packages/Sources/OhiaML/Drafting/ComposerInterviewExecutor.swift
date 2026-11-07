import CryptoKit
import Foundation

public enum ComposerInterviewExecutionError: Error, Sendable, Equatable {
    case nodeIsNotCurrent(String)
    case nodeIsNotAnswered(String)
    case repairAlreadyPending
    case invalidAnswer(nodeID: String)
    case residualDetailRequired(nodeID: String)
    case repairAnswerMissing(String)
    case invalidRepairPatch(String)
    case invalidRepairChoice(String)
}

public struct ComposerInterviewTranscriptEntry: Sendable, Equatable, Identifiable {
    public var id: String { node.id }
    public let ordinal: Int
    public let node: ComposerInterviewNode
    public let answer: ComposerInterviewAnswer?
    public let grounding: QuestionGrounding?
    public let displayText: String
}

public struct ComposerInterviewProjection: Sendable, Equatable {
    public let currentNode: ComposerInterviewNode?
    public let transcript: [ComposerInterviewTranscriptEntry]
    public let pathNodeIDs: [String]
    public let isTerminal: Bool
    public let pendingRepairAnswer: ComposerInterviewAnswer?
    public let nodesNeedingGrounding: [ComposerInterviewNode]
    public let unresolvedReachableNodeIDs: [String]

    public var decidedCount: Int { transcript.count }
}

public struct ComposerInterviewReopenResult: Sendable, Equatable {
    public let state: ComposerInterviewState
    public let researchOverlay: ComposerDecisionResearchOverlay?
}

public enum ComposerInterviewExecutor {
    public static func project(
        _ state: ComposerInterviewState
    ) -> ComposerInterviewProjection {
        let graph = EffectiveGraph(state: state)
        let answersByNodeID = state.answers.reduce(
            into: [String: ComposerInterviewAnswer]()
        ) { $0[$1.nodeID] = $1 }
        let groundingsByNodeID = state.groundings.reduce(
            into: [String: QuestionGrounding]()
        ) { $0[$1.questionID] = $1 }

        var currentNode: ComposerInterviewNode?
        var transcript: [ComposerInterviewTranscriptEntry] = []
        var pathNodeIDs: [String] = []
        var visited = Set<String>()
        var nodeID = state.baseProtocol.rootNodeID
        var isTerminal = false

        while visited.insert(nodeID).inserted, let node = graph.nodeMap[nodeID] {
            pathNodeIDs.append(nodeID)
            if node.kind == .terminal {
                isTerminal = nodeID == state.baseProtocol.terminalNodeID
                break
            }

            // An earlier answer made this question irrelevant: it is neither
            // asked nor recorded, and the interview continues past it.
            if let condition = node.condition,
               !isMet(condition, transcript: transcript),
               let skipNextNodeID = node.skipNextNodeID {
                nodeID = skipNextNodeID
                continue
            }

            if let answer = answersByNodeID[nodeID],
               let route = answerRoute(
                   for: answer,
                   node: node,
                   acceptedPatches: state.acceptedPatches
               ) {
                transcript.append(ComposerInterviewTranscriptEntry(
                    ordinal: transcript.count + 1,
                    node: node,
                    answer: answer,
                    grounding: nil,
                    displayText: answerDisplayText(answer, node: node)
                ))
                nodeID = route
                continue
            }

            if node.authority == .evidenceFact,
               let grounding = groundingsByNodeID[nodeID],
               let route = groundingRoute(
                   for: grounding,
                   node: node,
                   evidenceFingerprint: state.evidenceFingerprint
               ) {
                transcript.append(ComposerInterviewTranscriptEntry(
                    ordinal: transcript.count + 1,
                    node: node,
                    answer: nil,
                    grounding: grounding,
                    displayText: groundingDisplayText(grounding, node: node)
                ))
                nodeID = route
                continue
            }

            currentNode = node
            break
        }

        let pendingRepairAnswer = state.answers.first(where: isPendingRepair)
        let nodesNeedingGrounding = graph.orderedNodes.filter { node in
            guard node.kind == .question,
                  node.authority == .evidenceFact,
                  answersByNodeID[node.id] == nil else {
                return false
            }
            return state.groundings.contains(where: {
                QuestionGroundingValidation.isCurrent(
                    $0,
                    matching: node,
                    evidenceFingerprint: state.evidenceFingerprint
                )
            }) == false
        }
        let unresolvedReachableNodeIDs = currentNode.map {
            askableQuestionNodeIDs(
                reachableQuestionNodeIDs(startingAt: $0.id, graph: graph),
                transcript: transcript,
                graph: graph
            )
        } ?? []

        return ComposerInterviewProjection(
            currentNode: currentNode,
            transcript: transcript,
            pathNodeIDs: pathNodeIDs,
            isTerminal: isTerminal,
            pendingRepairAnswer: pendingRepairAnswer,
            nodesNeedingGrounding: nodesNeedingGrounding,
            unresolvedReachableNodeIDs: unresolvedReachableNodeIDs
        )
    }

    public static func commit(
        nodeID: String,
        selectedOptionID: String?,
        freeText: String?,
        skipped: Bool,
        answerID: UUID = UUID(),
        committedAt: Date = .now,
        in state: ComposerInterviewState
    ) throws -> ComposerInterviewState {
        let projection = project(state)
        guard projection.pendingRepairAnswer == nil else {
            throw ComposerInterviewExecutionError.repairAlreadyPending
        }
        guard let node = projection.currentNode, node.id == nodeID else {
            throw ComposerInterviewExecutionError.nodeIsNotCurrent(nodeID)
        }

        let suppliedText = freeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFreeText = suppliedText?.isEmpty == false
        let storedFreeText = hasFreeText ? freeText : nil
        let selectedOption: ComposerInterviewOption?

        if skipped {
            guard selectedOptionID == nil, !hasFreeText else {
                throw ComposerInterviewExecutionError.invalidAnswer(nodeID: nodeID)
            }
            selectedOption = nil
        } else {
            switch node.responseType {
            case .multipleChoice:
                // Typed words alone answer a choice question: the one repair
                // reads which choice, if any, they mean.
                guard let selectedOptionID else {
                    guard hasFreeText else {
                        throw ComposerInterviewExecutionError.invalidAnswer(nodeID: nodeID)
                    }
                    // Typing only a choice's label picks it, and a choice in
                    // the author's words needs more than that ("No").
                    if node.options.contains(where: {
                        $0.kind == .authorWords && $0.needsMoreWords(than: suppliedText)
                    }) {
                        throw ComposerInterviewExecutionError.residualDetailRequired(nodeID: nodeID)
                    }
                    selectedOption = nil
                    break
                }
                guard let option = node.options.first(where: { $0.id == selectedOptionID }) else {
                    throw ComposerInterviewExecutionError.invalidAnswer(nodeID: nodeID)
                }
                if option.needsMoreWords(than: suppliedText) {
                    throw ComposerInterviewExecutionError.residualDetailRequired(nodeID: nodeID)
                }
                selectedOption = option
            case .freeText:
                guard selectedOptionID == nil, hasFreeText else {
                    throw ComposerInterviewExecutionError.invalidAnswer(nodeID: nodeID)
                }
                selectedOption = nil
            case nil:
                throw ComposerInterviewExecutionError.invalidAnswer(nodeID: nodeID)
            }
        }

        let fingerprint = answerFingerprint(
            nodeID: nodeID,
            selectedOptionID: selectedOption?.id,
            freeText: storedFreeText,
            skipped: skipped
        )
        let provisional = ComposerInterviewAnswer(
            id: answerID,
            nodeID: nodeID,
            selectedOptionID: selectedOption?.id,
            freeText: storedFreeText,
            skipped: skipped,
            committedAt: committedAt,
            answerFingerprint: fingerprint,
            repairDisposition: .notRequired
        )
        let disposition: ComposerInterviewRepairDisposition
        switch ComposerInterviewRepairer.requirement(for: provisional, in: node) {
        case .notRequired:
            disposition = .notRequired
        case .required:
            disposition = .pending(answerFingerprint: fingerprint)
        case .incompleteRequiredDetail:
            throw ComposerInterviewExecutionError.residualDetailRequired(nodeID: nodeID)
        }

        var updated = state
        updated.answers.append(ComposerInterviewAnswer(
            id: provisional.id,
            nodeID: provisional.nodeID,
            selectedOptionID: provisional.selectedOptionID,
            freeText: provisional.freeText,
            skipped: provisional.skipped,
            committedAt: provisional.committedAt,
            answerFingerprint: provisional.answerFingerprint,
            repairDisposition: disposition
        ))
        return updated
    }

    /// Records the one repair of a typed answer. `typedReading` is what the
    /// typed words mean on a choice question (nil: the repair could not tell);
    /// routing follows it instead of the picked choice.
    public static func recordRepair(
        _ outcome: ComposerInterviewRepairOutcome,
        patch: ComposerInterviewPatch? = nil,
        typedReading: ComposerInterviewTypedReading? = nil,
        answerFingerprint: String,
        in state: ComposerInterviewState
    ) throws -> ComposerInterviewState {
        guard let answerIndex = state.answers.firstIndex(where: {
            $0.answerFingerprint == answerFingerprint
                && isPendingRepair($0)
        }) else {
            throw ComposerInterviewExecutionError.repairAnswerMissing(answerFingerprint)
        }
        let answer = state.answers[answerIndex]
        if let typedReading {
            guard let node = EffectiveGraph(state: state).nodeMap[answer.nodeID],
                  node.responseType == .multipleChoice,
                  typedReading.optionID.map({ optionID in
                      node.options.contains(where: { $0.id == optionID })
                  }) ?? true else {
                throw ComposerInterviewExecutionError.invalidRepairChoice(answerFingerprint)
            }
        }
        let disposition: ComposerInterviewRepairDisposition
        switch outcome {
        case .unchanged:
            guard patch == nil else {
                throw ComposerInterviewExecutionError.invalidRepairPatch(answerFingerprint)
            }
            disposition = .unchanged(answerFingerprint: answerFingerprint)
        case .failed:
            guard patch == nil else {
                throw ComposerInterviewExecutionError.invalidRepairPatch(answerFingerprint)
            }
            disposition = .failed(answerFingerprint: answerFingerprint)
        case .applied:
            guard let patch,
                  patch.triggerNodeID == answer.nodeID,
                  patch.triggerAnswerFingerprint == answerFingerprint else {
                throw ComposerInterviewExecutionError.invalidRepairPatch(answerFingerprint)
            }
            disposition = .applied(
                answerFingerprint: answerFingerprint,
                patchID: patch.id
            )
        }

        var updated = state
        updated.answers[answerIndex] = answer.recordingRepair(
            disposition,
            typedReading: typedReading
        )
        if let patch {
            updated.acceptedPatches.append(patch)
        }
        return updated
    }

    public static func recordRepair(
        _ result: ComposerInterviewRepairResult,
        answerFingerprint: String,
        in state: ComposerInterviewState
    ) throws -> ComposerInterviewState {
        try recordRepair(
            result.outcome,
            patch: result.patch,
            typedReading: result.typedReading,
            answerFingerprint: answerFingerprint,
            in: state
        )
    }

    /// What an answer stands for when the interview routes on it and tests the
    /// conditions of the questions that depend on it.
    enum Stance: Equatable {
        /// The answer stands for this choice.
        case choice(String)
        /// The answer stands for no choice: it was skipped, is free text, or
        /// its typed words mean none of the choices.
        case noChoice
        /// Typed words not yet read (the repair is pending, could not tell,
        /// or the answer predates reading): any choice may be meant, so the
        /// questions that depend on it stay open rather than being dropped.
        case unread
    }

    /// A pick with no typed words stands for the pick. Typed words override
    /// the pick: they stand for the choice the one repair read them as
    /// meaning, for the question's open "Other" choice (or no choice) when
    /// they mean none, and are unread until the repair says. The picked
    /// choice never steers past typed words.
    static func stance(
        of answer: ComposerInterviewAnswer,
        to node: ComposerInterviewNode
    ) -> Stance {
        guard !answer.skipped, node.responseType == .multipleChoice else { return .noChoice }
        func choice(_ optionID: String?) -> String? {
            optionID.flatMap { id in node.options.contains(where: { $0.id == id }) ? id : nil }
        }
        guard hasTypedWords(answer) else {
            return choice(answer.selectedOptionID).map(Stance.choice) ?? .noChoice
        }
        // Words completing a choice in the author's words stand for it.
        if let picked = choice(answer.selectedOptionID),
           node.options.first(where: { $0.id == picked })?.kind == .authorWords {
            return .choice(picked)
        }
        guard let reading = answer.typedReading else { return .unread }
        guard let optionID = reading.optionID else {
            return node.options.first(where: { $0.kind == .otherUnanticipated }).map { .choice($0.id) }
                ?? .noChoice
        }
        return choice(optionID).map(Stance.choice) ?? .unread
    }

    /// Whether `answer` to the condition's question makes a question with
    /// that condition relevant. Unread typed words leave it relevant.
    public static func satisfies(
        _ condition: ComposerInterviewCondition,
        answer: ComposerInterviewAnswer,
        to node: ComposerInterviewNode
    ) -> Bool {
        switch stance(of: answer, to: node) {
        case .choice(let optionID): condition.optionIDs.contains(optionID)
        case .noChoice: false
        case .unread: true
        }
    }

    /// Where the interview continues after `answer` to `node`, before any
    /// repair replaced that continuation. Typed words that stand for no
    /// choice, or are unread, take the question's skip route, which rejoins
    /// the interview past the routes particular to one choice.
    public static func continuationNodeID(
        after answer: ComposerInterviewAnswer,
        to node: ComposerInterviewNode
    ) -> String? {
        if answer.skipped {
            return node.skipNextNodeID
        }
        switch node.responseType {
        case .multipleChoice:
            switch stance(of: answer, to: node) {
            case .choice(let optionID):
                return node.options.first(where: { $0.id == optionID })?.nextNodeID
            case .noChoice, .unread:
                return hasTypedWords(answer) ? node.skipNextNodeID : nil
            }
        case .freeText:
            return node.answeredNextNodeID
        case nil:
            return nil
        }
    }

    private static func hasTypedWords(_ answer: ComposerInterviewAnswer) -> Bool {
        answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public static func reopen(
        nodeID: String,
        in state: ComposerInterviewState,
        researchOverlay: ComposerDecisionResearchOverlay?
    ) throws -> ComposerInterviewReopenResult {
        let projection = project(state)
        guard projection.transcript.contains(where: { $0.node.id == nodeID }),
              let pathIndex = projection.pathNodeIDs.firstIndex(of: nodeID) else {
            throw ComposerInterviewExecutionError.nodeIsNotAnswered(nodeID)
        }

        let prunedNodeIDs = Set(projection.pathNodeIDs[pathIndex...])
        var updated = state
        updated.answers.removeAll { prunedNodeIDs.contains($0.nodeID) }
        updated.groundings.removeAll { prunedNodeIDs.contains($0.questionID) }
        updated.acceptedPatches.removeAll { patch in
            prunedNodeIDs.contains(patch.triggerNodeID)
        }

        return ComposerInterviewReopenResult(
            state: updated,
            researchOverlay: nil
        )
    }

    public static func answerFingerprint(
        nodeID: String,
        selectedOptionID: String?,
        freeText: String?,
        skipped: Bool
    ) -> String {
        let fields = [
            nodeID,
            selectedOptionID ?? "",
            freeText ?? "",
            skipped ? "1" : "0",
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func answerRoute(
        for answer: ComposerInterviewAnswer,
        node: ComposerInterviewNode,
        acceptedPatches: [ComposerInterviewPatch]
    ) -> String? {
        if !answer.skipped,
           case .applied(let fingerprint, let patchID) = answer.repairDisposition,
           fingerprint == answer.answerFingerprint,
           let patch = acceptedPatches.first(where: {
               $0.id == patchID
                   && $0.triggerNodeID == node.id
                   && $0.triggerAnswerFingerprint == answer.answerFingerprint
           }) {
            return patch.replacementEntryNodeID
        }
        return continuationNodeID(after: answer, to: node)
    }

    private static func groundingRoute(
        for grounding: QuestionGrounding,
        node: ComposerInterviewNode,
        evidenceFingerprint: String
    ) -> String? {
        guard QuestionGroundingValidation.isResolvedFact(
            grounding,
            matching: node,
            evidenceFingerprint: evidenceFingerprint
        ) else {
            return nil
        }
        switch node.responseType {
        case .multipleChoice:
            guard let selectedOptionID = grounding.selectedOptionID else { return nil }
            return node.options.first(where: { $0.id == selectedOptionID })?.nextNodeID
        case .freeText:
            return node.answeredNextNodeID
        case nil:
            return nil
        }
    }

    private static func answerDisplayText(
        _ answer: ComposerInterviewAnswer,
        node: ComposerInterviewNode
    ) -> String {
        if answer.skipped {
            return "skipped — the draft decides"
        }
        if let freeText = answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !freeText.isEmpty {
            return freeText
        }
        if let selectedOptionID = answer.selectedOptionID,
           let option = node.options.first(where: { $0.id == selectedOptionID }) {
            return option.label
        }
        return ""
    }

    private static func groundingDisplayText(
        _ grounding: QuestionGrounding,
        node: ComposerInterviewNode
    ) -> String {
        if let answer = grounding.answerText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !answer.isEmpty {
            return answer
        }
        if let selectedOptionID = grounding.selectedOptionID,
           let option = node.options.first(where: { $0.id == selectedOptionID }) {
            return option.label
        }
        return ""
    }

    private static func isPendingRepair(_ answer: ComposerInterviewAnswer) -> Bool {
        guard case .pending(let fingerprint) = answer.repairDisposition else {
            return false
        }
        return fingerprint == answer.answerFingerprint
    }

    /// A condition is met when its parent's answer stands for one of its
    /// options (the author's pick, the choice their typed words mean, or the
    /// option evidence resolved), or is typed words not yet read. A skipped or
    /// unasked parent, or typed words that mean another choice, leave its
    /// dependent questions irrelevant.
    private static func isMet(
        _ condition: ComposerInterviewCondition,
        transcript: [ComposerInterviewTranscriptEntry]
    ) -> Bool {
        guard let entry = transcript.first(where: { $0.node.id == condition.nodeID }) else {
            return false
        }
        if let answer = entry.answer {
            return satisfies(condition, answer: answer, to: entry.node)
        }
        return entry.grounding?.selectedOptionID.map(condition.optionIDs.contains) ?? false
    }

    /// The reachable questions that can still be asked. A question whose
    /// condition an answer already failed, or whose parent can no longer be
    /// asked, is not an open decision the draft must leave unresolved.
    private static func askableQuestionNodeIDs(
        _ reachable: [String],
        transcript: [ComposerInterviewTranscriptEntry],
        graph: EffectiveGraph
    ) -> [String] {
        let open = Set(reachable)
        var memo: [String: Bool] = [:]
        func askable(_ nodeID: String, visiting: Set<String>) -> Bool {
            if let cached = memo[nodeID] { return cached }
            guard let condition = graph.nodeMap[nodeID]?.condition else { return true }
            let result: Bool
            if transcript.contains(where: { $0.node.id == condition.nodeID }) {
                result = isMet(condition, transcript: transcript)
            } else if open.contains(condition.nodeID), !visiting.contains(condition.nodeID) {
                result = askable(condition.nodeID, visiting: visiting.union([nodeID]))
            } else {
                result = false
            }
            memo[nodeID] = result
            return result
        }
        return reachable.filter { askable($0, visiting: []) }
    }

    private static func reachableQuestionNodeIDs(
        startingAt rootNodeID: String,
        graph: EffectiveGraph
    ) -> [String] {
        var reachable = Set<String>()
        var pending = [rootNodeID]
        while let nodeID = pending.popLast() {
            guard reachable.insert(nodeID).inserted,
                  let node = graph.nodeMap[nodeID],
                  node.kind == .question else {
                continue
            }
            pending.append(contentsOf: node.outgoingNodeIDs.reversed())
        }
        return graph.orderedNodes.compactMap { node in
            node.kind == .question && reachable.contains(node.id) ? node.id : nil
        }
    }

    private struct EffectiveGraph {
        let orderedNodes: [ComposerInterviewNode]
        let nodeMap: [String: ComposerInterviewNode]

        init(state: ComposerInterviewState) {
            orderedNodes = state.baseProtocol.nodes
                + state.acceptedPatches.flatMap(\.nodes)
            nodeMap = orderedNodes.reduce(into: [:]) { $0[$1.id] = $1 }
        }
    }
}
