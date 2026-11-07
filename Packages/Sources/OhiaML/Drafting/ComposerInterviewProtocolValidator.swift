import Foundation

public enum ComposerInterviewValidationError: Error, Sendable, Equatable {
    case invalidIdentifier(String)
    case duplicateNodeID(String)
    case duplicateOptionID(String)
    case missingRoot(String)
    case missingTerminal(String)
    case multipleTerminals
    case invalidTerminalNode(String)
    case invalidQuestionNode(String)
    case invalidOptionCount(nodeID: String, minimum: Int, maximum: Int)
    case duplicateOptionLabel(nodeID: String, label: String)
    case multipleResidualOptions(nodeID: String)
    case missingRoute(sourceNodeID: String, targetNodeID: String)
    case cycle(nodeID: String)
    case unreachableNode(String)
    case repeatedVariable(String)
    case tooManyQuestions(maximum: Int)
    case pathTooDeep(maximum: Int)
    case stalePatchContext
    case patchIdentityMismatch
    case duplicatePatchID(String)
    case patchEntryMissing(String)
    case patchNodeIDCollides(String)
    case patchRoutesToAnsweredNode(nodeID: String)
    case patchRoutesOutsideContinuation(nodeID: String)
    case invalidCondition(nodeID: String)
}

extension ComposerInterviewValidationError: CustomStringConvertible {
    /// Plain wording for a correction prompt and a failure record.
    public var description: String {
        switch self {
        case .invalidIdentifier(let id): "invalid identifier “\(id)”"
        case .duplicateNodeID(let id): "node id “\(id)” is used twice"
        case .duplicateOptionID(let id): "option id “\(id)” is used twice"
        case .missingRoot(let id): "root node “\(id)” does not exist"
        case .missingTerminal(let id): "terminal node “\(id)” does not exist"
        case .multipleTerminals: "more than one terminal node"
        case .invalidTerminalNode(let id): "node “\(id)” is named as the terminal but is not one"
        case .invalidQuestionNode(let id): "question node “\(id)” is malformed"
        case .invalidOptionCount(let nodeID, let minimum, let maximum):
            "node “\(nodeID)” must have between \(minimum) and \(maximum) options"
        case .duplicateOptionLabel(let nodeID, let label): "node “\(nodeID)” repeats the option label “\(label)”"
        case .multipleResidualOptions(let nodeID): "node “\(nodeID)” has more than one residual option"
        case .missingRoute(let sourceNodeID, let targetNodeID):
            "node “\(sourceNodeID)” routes to “\(targetNodeID)”, which does not exist"
        case .cycle(let nodeID): "the graph has a cycle through node “\(nodeID)”"
        case .unreachableNode(let id): "node “\(id)” cannot be reached from the root"
        case .repeatedVariable(let variable): "variable “\(variable)” is asked more than once on one path"
        case .tooManyQuestions(let maximum): "more than \(maximum) question nodes"
        case .pathTooDeep(let maximum): "a question path is deeper than \(maximum)"
        case .stalePatchContext: "the patch context is stale"
        case .patchIdentityMismatch: "the patch does not match the expected trigger"
        case .duplicatePatchID(let id): "patch id “\(id)” is used twice"
        case .patchEntryMissing(let id): "patch entry node “\(id)” is missing"
        case .patchNodeIDCollides(let id): "patch node id “\(id)” collides with an existing node"
        case .patchRoutesToAnsweredNode(let nodeID): "patch routes to already answered node “\(nodeID)”"
        case .patchRoutesOutsideContinuation(let nodeID): "patch routes outside its continuation at node “\(nodeID)”"
        case .invalidCondition(let nodeID):
            "question “\(nodeID)” depends on answers that are not distinct options of a multiple-choice question before it"
        }
    }
}

public struct ComposerInterviewPatchValidationContext: Sendable, Equatable {
    public let baseProtocol: ComposerInterviewProtocol
    public let acceptedPatches: [ComposerInterviewPatch]
    public let answeredNodeIDs: Set<String>
    public let answeredVariableIDs: Set<String>
    public let requestProtocolFingerprint: String
    public let currentProtocolFingerprint: String
    public let requestGenerationEpoch: Int
    public var currentGenerationEpoch: Int
    public let requestAnsweredPrefixFingerprint: String
    public let currentAnsweredPrefixFingerprint: String
    public let expectedTriggerNodeID: String
    public let expectedTriggerAnswerFingerprint: String
    public let expectedContinuationNodeID: String
    public let maximumTotalQuestionNodes: Int
    public let maximumPathQuestionNodes: Int

    public init(
        baseProtocol: ComposerInterviewProtocol,
        acceptedPatches: [ComposerInterviewPatch],
        answeredNodeIDs: Set<String>,
        answeredVariableIDs: Set<String>,
        requestProtocolFingerprint: String,
        currentProtocolFingerprint: String,
        requestGenerationEpoch: Int,
        currentGenerationEpoch: Int,
        requestAnsweredPrefixFingerprint: String,
        currentAnsweredPrefixFingerprint: String,
        expectedTriggerNodeID: String,
        expectedTriggerAnswerFingerprint: String,
        expectedContinuationNodeID: String,
        maximumTotalQuestionNodes: Int = ComposerInterviewProtocolValidator.maximumQuestionNodes,
        maximumPathQuestionNodes: Int = ComposerInterviewProtocolValidator.maximumPathQuestionNodes
    ) {
        self.baseProtocol = baseProtocol
        self.acceptedPatches = acceptedPatches
        self.answeredNodeIDs = answeredNodeIDs
        self.answeredVariableIDs = answeredVariableIDs
        self.requestProtocolFingerprint = requestProtocolFingerprint
        self.currentProtocolFingerprint = currentProtocolFingerprint
        self.requestGenerationEpoch = requestGenerationEpoch
        self.currentGenerationEpoch = currentGenerationEpoch
        self.requestAnsweredPrefixFingerprint = requestAnsweredPrefixFingerprint
        self.currentAnsweredPrefixFingerprint = currentAnsweredPrefixFingerprint
        self.expectedTriggerNodeID = expectedTriggerNodeID
        self.expectedTriggerAnswerFingerprint = expectedTriggerAnswerFingerprint
        self.expectedContinuationNodeID = expectedContinuationNodeID
        self.maximumTotalQuestionNodes = maximumTotalQuestionNodes
        self.maximumPathQuestionNodes = maximumPathQuestionNodes
    }
}

public enum ComposerInterviewProtocolValidator {
    public static let maximumQuestionNodes = 10
    public static let maximumPathQuestionNodes = 6
    public static let minimumOptionCount = 2
    public static let maximumOptionCount = 4

    @discardableResult
    public static func validate(
        _ protocolGraph: ComposerInterviewProtocol
    ) throws -> ComposerInterviewProtocol {
        let protocolGraph = normalizingAuthorities(in: protocolGraph)
        try validateIdentifiersAndShapes(protocolGraph)

        let nodeMap = Dictionary(uniqueKeysWithValues: protocolGraph.nodes.map { ($0.id, $0) })
        guard nodeMap[protocolGraph.rootNodeID] != nil else {
            throw ComposerInterviewValidationError.missingRoot(protocolGraph.rootNodeID)
        }
        guard let terminal = nodeMap[protocolGraph.terminalNodeID] else {
            throw ComposerInterviewValidationError.missingTerminal(protocolGraph.terminalNodeID)
        }
        guard terminal.kind == .terminal else {
            throw ComposerInterviewValidationError.invalidTerminalNode(terminal.id)
        }
        guard protocolGraph.nodes.filter({ $0.kind == .terminal }).count == 1 else {
            throw ComposerInterviewValidationError.multipleTerminals
        }
        guard protocolGraph.questionNodes.count <= maximumQuestionNodes else {
            throw ComposerInterviewValidationError.tooManyQuestions(
                maximum: maximumQuestionNodes
            )
        }

        try validateRoutes(in: protocolGraph.nodes, nodeMap: nodeMap)

        var visited = Set<String>()
        try traverse(
            nodeID: protocolGraph.rootNodeID,
            terminalNodeID: protocolGraph.terminalNodeID,
            nodeMap: nodeMap,
            answeredNodeIDs: [],
            pathNodeIDs: [],
            pathVariableIDs: [],
            questionDepth: 0,
            maximumQuestionDepth: maximumPathQuestionNodes,
            visited: &visited
        )

        if let unreachable = protocolGraph.nodes.first(where: { !visited.contains($0.id) }) {
            throw ComposerInterviewValidationError.unreachableNode(unreachable.id)
        }
        try validateConditions(of: protocolGraph.nodes, nodeMap: nodeMap)

        return protocolGraph
    }

    public static func effectiveAuthority(
        scope: ComposerInterviewScope,
        questionText: String,
        declaredAuthority: ComposerInterviewAuthority
    ) -> ComposerInterviewAuthority {
        guard declaredAuthority == .evidenceFact, scope != .approach else {
            return .userDecision
        }

        let normalized = normalizeQuestionText(questionText)
        let words = Set(normalized.split(separator: " ").map(String.init))
        let decisionWords: Set<String> = [
            "accept", "approval", "approve", "choice", "choose", "commit",
            "commitment", "decide", "decline", "intent", "intend",
            "preference", "prefer", "prioritize", "priority", "promise",
            "recommend", "recommendation", "strategy", "strategic", "tone",
            "willing", "willingness",
        ]
        let decisionPhrases = [
            "should ", "do you want", "would you like", "are you willing",
            "will you", "can you", "could you", "shall i", "will i",
            "do i want", "plan to", "need to", "work for you", "works for you",
            "best for you", "you available", "your availability",
            "convenient for you", "suitable for you",
        ]
        if !words.isDisjoint(with: decisionWords)
            || decisionPhrases.contains(where: { containsPhrase($0, in: normalized) }) {
            return .userDecision
        }

        let objectiveWords: Set<String> = [
            "address", "date", "identifier", "location", "name", "number",
            "time", "what", "when", "where", "who",
        ]
        let hasObjectiveShape = !words.isDisjoint(with: objectiveWords)
            || containsPhrase("how many", in: normalized)
            || containsPhrase("how much", in: normalized)
        return hasObjectiveShape ? .evidenceFact : .userDecision
    }

    @discardableResult
    public static func validate(
        patch: ComposerInterviewPatch,
        context: ComposerInterviewPatchValidationContext
    ) throws -> ComposerInterviewPatch {
        let patch = normalizingAuthorities(in: patch)
        guard context.requestProtocolFingerprint == context.currentProtocolFingerprint,
              context.requestGenerationEpoch == context.currentGenerationEpoch,
              context.requestAnsweredPrefixFingerprint
                == context.currentAnsweredPrefixFingerprint else {
            throw ComposerInterviewValidationError.stalePatchContext
        }
        guard patch.triggerNodeID == context.expectedTriggerNodeID,
              patch.triggerAnswerFingerprint == context.expectedTriggerAnswerFingerprint,
              patch.replacedContinuationNodeID == context.expectedContinuationNodeID else {
            throw ComposerInterviewValidationError.patchIdentityMismatch
        }

        try validate(context.baseProtocol)
        try requireValidIdentifier(patch.id)
        try requireValidIdentifier(patch.triggerNodeID)
        try requireValidIdentifier(patch.replacedContinuationNodeID)
        try requireValidIdentifier(patch.replacementEntryNodeID)

        if context.acceptedPatches.contains(where: { $0.id == patch.id }) {
            throw ComposerInterviewValidationError.duplicatePatchID(patch.id)
        }

        let baseNodeIDs = Set(context.baseProtocol.nodes.map(\.id))
        let acceptedNodeIDs = Set(context.acceptedPatches.flatMap(\.nodes).map(\.id))
        var patchNodeIDs = Set<String>()
        var optionIDs = Set(
            context.baseProtocol.nodes.flatMap(\.options).map(\.id)
                + context.acceptedPatches.flatMap(\.nodes).flatMap(\.options).map(\.id)
        )

        for node in patch.nodes {
            try validateNodeIdentifierAndShape(node, globalOptionIDs: &optionIDs)
            guard patchNodeIDs.insert(node.id).inserted else {
                throw ComposerInterviewValidationError.duplicateNodeID(node.id)
            }
            guard !baseNodeIDs.contains(node.id), !acceptedNodeIDs.contains(node.id) else {
                throw ComposerInterviewValidationError.patchNodeIDCollides(node.id)
            }
            guard node.kind == .question else {
                throw ComposerInterviewValidationError.invalidQuestionNode(node.id)
            }
        }

        let existingNodes = context.baseProtocol.nodes
            + context.acceptedPatches.flatMap(\.nodes)
        let existingNodeMap = existingNodes.reduce(
            into: [String: ComposerInterviewNode]()
        ) { nodeMap, node in
            nodeMap[node.id] = node
        }
        let allowedContinuationNodeIDs = reachableNodeIDs(
            startingAt: context.expectedContinuationNodeID,
            nodeMap: existingNodeMap
        )
        // An answer can make all remaining questions unnecessary. Only an
        // empty patch may enter the existing reachable terminal directly;
        // other repairs must still enter one of their own question nodes.
        let endsInterview = patch.nodes.isEmpty
            && patch.replacementEntryNodeID == context.baseProtocol.terminalNodeID
            && allowedContinuationNodeIDs.contains(patch.replacementEntryNodeID)
        guard patchNodeIDs.contains(patch.replacementEntryNodeID) || endsInterview else {
            throw ComposerInterviewValidationError.patchEntryMissing(
                patch.replacementEntryNodeID
            )
        }
        for node in patch.nodes {
            for targetNodeID in node.outgoingNodeIDs
            where !patchNodeIDs.contains(targetNodeID)
                && !context.answeredNodeIDs.contains(targetNodeID)
                && existingNodeMap[targetNodeID] != nil
                && !allowedContinuationNodeIDs.contains(targetNodeID) {
                throw ComposerInterviewValidationError.patchRoutesOutsideContinuation(
                    nodeID: targetNodeID
                )
            }
        }

        let combinedNodes = existingNodes + patch.nodes
        let nodeMap = combinedNodes.reduce(into: [String: ComposerInterviewNode]()) {
            $0[$1.id] = $1
        }
        try validateRoutes(
            in: patch.nodes,
            nodeMap: nodeMap,
            answeredNodeIDs: context.answeredNodeIDs
        )

        var visited = Set<String>()
        try traverse(
            nodeID: patch.replacementEntryNodeID,
            terminalNodeID: context.baseProtocol.terminalNodeID,
            nodeMap: nodeMap,
            answeredNodeIDs: context.answeredNodeIDs,
            pathNodeIDs: context.answeredNodeIDs,
            pathVariableIDs: context.answeredVariableIDs,
            questionDepth: context.answeredNodeIDs.count,
            maximumQuestionDepth: min(
                context.maximumPathQuestionNodes,
                maximumPathQuestionNodes
            ),
            visited: &visited
        )

        if let unreachablePatchNode = patch.nodes.first(where: { !visited.contains($0.id) }) {
            throw ComposerInterviewValidationError.unreachableNode(unreachablePatchNode.id)
        }
        try validateConditions(of: patch.nodes, nodeMap: nodeMap)

        let combinedQuestionCount = Set(
            combinedNodes.lazy.filter { $0.kind == .question }.map(\.id)
        ).count
        let effectiveMaximumQuestionNodes = min(
            context.maximumTotalQuestionNodes,
            maximumQuestionNodes
        )
        guard combinedQuestionCount <= effectiveMaximumQuestionNodes else {
            throw ComposerInterviewValidationError.tooManyQuestions(
                maximum: effectiveMaximumQuestionNodes
            )
        }
        return patch
    }

    /// A condition names distinct options of a multiple-choice question that
    /// routes to the conditioned node, so an answer to it can precede the node.
    private static func validateConditions(
        of nodes: [ComposerInterviewNode],
        nodeMap: [String: ComposerInterviewNode]
    ) throws {
        for node in nodes {
            guard let condition = node.condition else { continue }
            guard node.kind == .question,
                  condition.nodeID != node.id,
                  let parent = nodeMap[condition.nodeID],
                  parent.kind == .question,
                  parent.responseType == .multipleChoice,
                  !condition.optionIDs.isEmpty,
                  Set(condition.optionIDs).count == condition.optionIDs.count,
                  Set(condition.optionIDs).isSubset(of: parent.options.map(\.id)),
                  reachableNodeIDs(startingAt: parent.id, nodeMap: nodeMap).contains(node.id) else {
                throw ComposerInterviewValidationError.invalidCondition(nodeID: node.id)
            }
        }
    }

    private static func reachableNodeIDs(
        startingAt rootNodeID: String,
        nodeMap: [String: ComposerInterviewNode]
    ) -> Set<String> {
        var visited = Set<String>()
        var pending = [rootNodeID]
        while let nodeID = pending.popLast() {
            guard visited.insert(nodeID).inserted, let node = nodeMap[nodeID] else {
                continue
            }
            pending.append(contentsOf: node.outgoingNodeIDs)
        }
        return visited
    }

    private static func validateIdentifiersAndShapes(
        _ protocolGraph: ComposerInterviewProtocol
    ) throws {
        try requireValidIdentifier(protocolGraph.rootNodeID)
        try requireValidIdentifier(protocolGraph.terminalNodeID)

        var nodeIDs = Set<String>()
        var optionIDs = Set<String>()
        for node in protocolGraph.nodes {
            try validateNodeIdentifierAndShape(node, globalOptionIDs: &optionIDs)
            guard nodeIDs.insert(node.id).inserted else {
                throw ComposerInterviewValidationError.duplicateNodeID(node.id)
            }
        }
    }

    private static func normalizingAuthorities(
        in protocolGraph: ComposerInterviewProtocol
    ) -> ComposerInterviewProtocol {
        ComposerInterviewProtocol(
            rootNodeID: protocolGraph.rootNodeID,
            terminalNodeID: protocolGraph.terminalNodeID,
            nodes: protocolGraph.nodes.map { node in
                guard node.kind == .question,
                      let scope = node.scope,
                      let authority = node.authority,
                      let text = node.text else {
                    return node
                }
                return ComposerInterviewNode(
                    id: node.id,
                    kind: node.kind,
                    variableID: node.variableID,
                    scope: scope,
                    authority: effectiveAuthority(
                        scope: scope,
                        questionText: text,
                        declaredAuthority: authority
                    ),
                    text: text,
                    responseType: node.responseType,
                    options: node.options,
                    answeredNextNodeID: node.answeredNextNodeID,
                    skipNextNodeID: node.skipNextNodeID,
                    impactWeight: node.impactWeight,
                    condition: node.condition
                )
            }
        )
    }

    private static func normalizingAuthorities(
        in patch: ComposerInterviewPatch
    ) -> ComposerInterviewPatch {
        ComposerInterviewPatch(
            id: patch.id,
            triggerNodeID: patch.triggerNodeID,
            triggerAnswerFingerprint: patch.triggerAnswerFingerprint,
            replacedContinuationNodeID: patch.replacedContinuationNodeID,
            replacementEntryNodeID: patch.replacementEntryNodeID,
            nodes: patch.nodes.map { node in
                guard node.kind == .question else { return node }
                return ComposerInterviewNode(
                    id: node.id,
                    kind: node.kind,
                    variableID: node.variableID,
                    scope: node.scope,
                    authority: .userDecision,
                    text: node.text,
                    responseType: node.responseType,
                    options: node.options,
                    answeredNextNodeID: node.answeredNextNodeID,
                    skipNextNodeID: node.skipNextNodeID,
                    impactWeight: node.impactWeight,
                    condition: node.condition
                )
            }
        )
    }

    private static func validateNodeIdentifierAndShape(
        _ node: ComposerInterviewNode,
        globalOptionIDs: inout Set<String>
    ) throws {
        try requireValidIdentifier(node.id)

        switch node.kind {
        case .terminal:
            guard node.variableID == nil,
                  node.scope == nil,
                  node.authority == nil,
                  node.text == nil,
                  node.responseType == nil,
                  node.options.isEmpty,
                  node.answeredNextNodeID == nil,
                  node.skipNextNodeID == nil,
                  node.impactWeight == nil,
                  node.condition == nil else {
                throw ComposerInterviewValidationError.invalidTerminalNode(node.id)
            }

        case .question:
            guard let variableID = node.variableID,
                  let text = nonempty(node.text),
                  node.scope != nil,
                  node.authority != nil,
                  let responseType = node.responseType,
                  let skipNextNodeID = node.skipNextNodeID,
                  nonempty(skipNextNodeID) != nil else {
                throw ComposerInterviewValidationError.invalidQuestionNode(node.id)
            }
            _ = text
            try requireValidIdentifier(variableID)
            try requireValidIdentifier(skipNextNodeID)
            if let impactWeight = node.impactWeight,
               (!impactWeight.isFinite || !(0...1).contains(impactWeight)) {
                throw ComposerInterviewValidationError.invalidQuestionNode(node.id)
            }

            switch responseType {
            case .multipleChoice:
                guard node.answeredNextNodeID == nil,
                      (minimumOptionCount...maximumOptionCount).contains(node.options.count) else {
                    throw ComposerInterviewValidationError.invalidOptionCount(
                        nodeID: node.id,
                        minimum: minimumOptionCount,
                        maximum: maximumOptionCount
                    )
                }
            case .freeText:
                guard node.options.isEmpty,
                      let answeredNextNodeID = node.answeredNextNodeID,
                      nonempty(answeredNextNodeID) != nil else {
                    throw ComposerInterviewValidationError.invalidQuestionNode(node.id)
                }
                try requireValidIdentifier(answeredNextNodeID)
            }

            var normalizedLabels = Set<String>()
            var residualCount = 0
            for option in node.options {
                try requireValidIdentifier(option.id)
                try requireValidIdentifier(option.nextNodeID)
                guard globalOptionIDs.insert(option.id).inserted else {
                    throw ComposerInterviewValidationError.duplicateOptionID(option.id)
                }
                guard let label = nonempty(option.label) else {
                    throw ComposerInterviewValidationError.invalidQuestionNode(node.id)
                }
                let normalizedLabel = normalize(label)
                guard normalizedLabels.insert(normalizedLabel).inserted else {
                    throw ComposerInterviewValidationError.duplicateOptionLabel(
                        nodeID: node.id,
                        label: normalizedLabel
                    )
                }
                if option.kind == .otherUnanticipated {
                    residualCount += 1
                }
                guard option.draftEffects.allSatisfy({ nonempty($0) != nil }) else {
                    throw ComposerInterviewValidationError.invalidQuestionNode(node.id)
                }
            }
            guard residualCount <= 1 else {
                throw ComposerInterviewValidationError.multipleResidualOptions(
                    nodeID: node.id
                )
            }
        }
    }

    private static func validateRoutes(
        in sourceNodes: [ComposerInterviewNode],
        nodeMap: [String: ComposerInterviewNode],
        answeredNodeIDs: Set<String> = []
    ) throws {
        for node in sourceNodes {
            for targetNodeID in node.outgoingNodeIDs {
                if answeredNodeIDs.contains(targetNodeID) {
                    throw ComposerInterviewValidationError.patchRoutesToAnsweredNode(
                        nodeID: targetNodeID
                    )
                }
                guard nodeMap[targetNodeID] != nil else {
                    throw ComposerInterviewValidationError.missingRoute(
                        sourceNodeID: node.id,
                        targetNodeID: targetNodeID
                    )
                }
            }
        }
    }

    private static func traverse(
        nodeID: String,
        terminalNodeID: String,
        nodeMap: [String: ComposerInterviewNode],
        answeredNodeIDs: Set<String>,
        pathNodeIDs: Set<String>,
        pathVariableIDs: Set<String>,
        questionDepth: Int,
        maximumQuestionDepth: Int,
        visited: inout Set<String>
    ) throws {
        if answeredNodeIDs.contains(nodeID) {
            throw ComposerInterviewValidationError.patchRoutesToAnsweredNode(nodeID: nodeID)
        }
        if pathNodeIDs.contains(nodeID) {
            throw ComposerInterviewValidationError.cycle(nodeID: nodeID)
        }
        guard let node = nodeMap[nodeID] else {
            throw ComposerInterviewValidationError.missingRoute(
                sourceNodeID: nodeID,
                targetNodeID: nodeID
            )
        }

        visited.insert(nodeID)
        if nodeID == terminalNodeID {
            guard node.kind == .terminal else {
                throw ComposerInterviewValidationError.invalidTerminalNode(nodeID)
            }
            return
        }
        guard node.kind == .question, let variableID = node.variableID else {
            throw ComposerInterviewValidationError.invalidQuestionNode(nodeID)
        }

        let nextDepth = questionDepth + 1
        guard nextDepth <= maximumQuestionDepth else {
            throw ComposerInterviewValidationError.pathTooDeep(
                maximum: maximumQuestionDepth
            )
        }
        guard !pathVariableIDs.contains(variableID) else {
            throw ComposerInterviewValidationError.repeatedVariable(variableID)
        }

        var nextPathNodeIDs = pathNodeIDs
        nextPathNodeIDs.insert(nodeID)
        var nextPathVariableIDs = pathVariableIDs
        nextPathVariableIDs.insert(variableID)

        for targetNodeID in Set(node.outgoingNodeIDs) {
            try traverse(
                nodeID: targetNodeID,
                terminalNodeID: terminalNodeID,
                nodeMap: nodeMap,
                answeredNodeIDs: answeredNodeIDs,
                pathNodeIDs: nextPathNodeIDs,
                pathVariableIDs: nextPathVariableIDs,
                questionDepth: nextDepth,
                maximumQuestionDepth: maximumQuestionDepth,
                visited: &visited
            )
        }
    }

    private static func requireValidIdentifier(_ identifier: String) throws {
        guard isValidIdentifier(identifier) else {
            throw ComposerInterviewValidationError.invalidIdentifier(identifier)
        }
    }

    private static func isValidIdentifier(_ identifier: String) -> Bool {
        let bytes = Array(identifier.utf8)
        guard (1...64).contains(bytes.count),
              let first = bytes.first,
              (Character("a").asciiValue!...Character("z").asciiValue!).contains(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (Character("a").asciiValue!...Character("z").asciiValue!).contains(byte)
                || (Character("0").asciiValue!...Character("9").asciiValue!).contains(byte)
                || byte == Character("_").asciiValue!
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The comparison key for option labels: two labels with the same key
    /// are the same choice.
    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func normalizeQuestionText(_ text: String) -> String {
        let lowercased = text.lowercased()
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func containsPhrase(_ phrase: String, in normalized: String) -> Bool {
        let needle = phrase.trimmingCharacters(in: .whitespaces)
        return normalized == needle
            || normalized.hasPrefix(needle + " ")
            || normalized.hasSuffix(" " + needle)
            || normalized.contains(" " + needle + " ")
    }
}
