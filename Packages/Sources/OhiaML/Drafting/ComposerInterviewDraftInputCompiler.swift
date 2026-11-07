import CryptoKit
import Foundation
import OhiaCore

public struct ComposerInterviewAcceptedDecision: Codable, Sendable, Equatable {
    public let nodeID: String
    public let variableID: String
    public let questionText: String
    public let selectedOptionID: String?
    public let selectedOptionLabel: String?
    public let rawFreeText: String?
    public let draftEffects: [String]
    /// The picked choice is completed by the typed words (a reconfirmation's
    /// No, then the author's answer now), rather than replaced by them.
    public var completesChoice: Bool? = nil

    /// What the author answered, as the writer reads it: their own words,
    /// or the picked option's effect when it says more than its label (a
    /// reconfirmation's "Yes" is the earlier answer itself), else the label.
    /// Typed words win, except words that only name the choice (typing
    /// "Yes"), which mean its effect.
    public var answerText: String? {
        let effect = draftEffects.first.flatMap { $0.isEmpty || $0 == selectedOptionLabel ? nil : $0 }
        if let rawFreeText { return effect.flatMap { $0 == rawFreeText ? nil : $0 } ?? rawFreeText }
        return effect ?? selectedOptionLabel
    }

    public var promptLine: String {
        if let rawFreeText {
            if completesChoice == true, let selectedOptionLabel {
                return "Q: \(questionText) → A: \(selectedOptionLabel): \(rawFreeText.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            if selectedOptionID != nil {
                return "Q: \(questionText) → User's custom answer (authoritative; selected answer superseded): \(rawFreeText)"
            }
            return "Q: \(questionText) → A: \(rawFreeText)"
        }
        return "Q: \(questionText) → A: \(selectedOptionLabel ?? "")"
    }
}

public struct ComposerInterviewEvidenceFact: Sendable, Equatable {
    public let nodeID: String
    public let variableID: String
    public let questionText: String
    public let selectedOptionID: String?
    public let answerText: String
    public let citations: [QuestionGroundingCitation]

    public var promptLine: String {
        let labels = citations.map(\.label).joined(separator: ", ")
        return "Q: \(questionText) → Established fact: \(answerText) [Sources: \(labels)]"
    }
}

public struct ComposerInterviewDeferredVariable: Sendable, Equatable {
    public let nodeID: String
    public let variableID: String
    public let questionText: String
    public let wasSkipped: Bool
    /// The incoming request the question was asked about, when the plan
    /// recorded it: it ties a sentence about that request to the open
    /// question even when the question was a paraphrase.
    public var anchorQuote: String? = nil
    /// For a question asking the author to stand by an earlier answer of
    /// theirs: that answer. Left open, the answer is what stays undecided:
    /// thanking them for what they sent, or anything else about their email,
    /// decides nothing.
    public var earlierAnswer: String? = nil

    /// How the line for a question on an earlier answer opens, and where
    /// their request follows it: the draft check reads the two apart.
    public static let earlierAnswerOpening = "Your earlier answer, asked about again: “"
    public static let theirRequestOpening = "” (their request: “"
    public static let theirRequestClosing = "”)"
    public static let earlierAnswerClosing = "”"
    /// What follows the quotes, read back from the end: the quoted words may
    /// hold quote marks of their own.
    public static func earlierAnswerStatus(skipped: Bool) -> String {
        ": \(skipped ? "skipped" : "unanswered") — unknown."
    }

    public var promptLine: String {
        if let earlierAnswer {
            let request = anchorQuote.map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ") }.flatMap { $0.isEmpty ? nil : $0 }
            let asked = request.map { "\(Self.theirRequestOpening)\($0)\(Self.theirRequestClosing)" } ?? Self.earlierAnswerClosing
            return "\(Self.earlierAnswerOpening)\(earlierAnswer)\(asked)\(Self.earlierAnswerStatus(skipped: wasSkipped)) Do not repeat, confirm or withdraw it, and invent no answer, preference, availability, or commitment in its place or on their request."
        }
        let about = anchorQuote.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || questionText.contains($0) ? nil : $0 }
            .map { " (about: “\($0)”)" } ?? ""
        if wasSkipped {
            return "\(questionText)\(about): skipped — unknown. Do not invent an answer, preference, availability, or commitment. Leave it out."
        }
        return "\(questionText)\(about): unanswered — unknown. Do not invent an answer, preference, availability, or commitment. Leave it out."
    }
}

public struct ComposerInterviewDraftInput: Sendable, Equatable {
    public let framing: ComposerInterviewFraming
    public let acceptedDecisions: [ComposerInterviewAcceptedDecision]
    public let evidenceFacts: [ComposerInterviewEvidenceFact]
    public let deferredVariables: [ComposerInterviewDeferredVariable]
    public let selectedSourceIDs: [UUID]
    public let draftGuidance: String?
    public let acceptedDecisionDigest: String
    public let acceptedDecisionDigestFingerprint: String
    public let replyContext: ComposerReplyContextReview?

    public var userDecisionLines: [String] {
        acceptedDecisions.map(\.promptLine)
    }

    public var draftingEffectLines: [String] {
        acceptedDecisions.flatMap(\.draftEffects)
    }

    public var evidenceFactLines: [String] {
        evidenceFacts.map(\.promptLine)
    }

    public var deferredVariableLines: [String] {
        deferredVariables.map(\.promptLine)
    }

    public var modelPromptLines: [String] {
        userDecisionLines
            + draftingEffectLines.map {
                "Selected-option effect (lower authority than raw answers): \($0)"
            }
            + evidenceFactLines
            + deferredVariableLines
    }

    public var draftingRuleDecisionLines: [String] { userDecisionLines }

    public var trainingDecisionLines: [String] { userDecisionLines }
}

public enum ComposerInterviewDraftInputCompiler {
    /// Invalidate evidence and routing, while keeping only instructions the user accepted.
    public static func rechecking(_ state: ComposerInterviewState) -> ComposerInterviewState {
        let decisions = compile(state: state, framing: .reply, selectedSources: [], draftGuidance: nil).acceptedDecisions
        return ComposerInterviewState(contractVersion: state.contractVersion,
            inputFingerprint: "", evidenceFingerprint: "", generationEpoch: state.generationEpoch,
            planningOutcome: .empty, baseProtocol: ComposerInterviewPlanner.emptyProtocol,
            carriedDecisions: decisions)
    }

    @MainActor
    public static func compile(
        draft: Draft,
        framing: ComposerInterviewFraming? = nil,
        selectedSources: [ComposerSource]? = nil
    ) -> ComposerInterviewDraftInput {
        let resolvedFraming = framing ?? (draft.kind == .userCompose ? .compose : .reply)
        let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON)
            ?? ComposerInterviewState(
                contractVersion: ComposerInterviewPlanner.contractVersion,
                inputFingerprint: "",
                evidenceFingerprint: "",
                generationEpoch: 0,
                planningOutcome: .empty,
                baseProtocol: ComposerInterviewPlanner.emptyProtocol
            )
        return compile(
            state: state,
            framing: resolvedFraming,
            selectedSources: selectedSources ?? ComposerSourceCoding.decode(draft.sourcesJSON),
            draftGuidance: draft.draftingInstruction
        )
    }

    public static func compile(
        state: ComposerInterviewState,
        framing: ComposerInterviewFraming,
        selectedSources: [ComposerSource],
        draftGuidance: String?
    ) -> ComposerInterviewDraftInput {
        let projection = ComposerInterviewExecutor.project(state)
        var acceptedDecisions: [ComposerInterviewAcceptedDecision] = state.carriedDecisions ?? []
        var evidenceFacts: [ComposerInterviewEvidenceFact] = []
        var deferredVariables: [ComposerInterviewDeferredVariable] = []

        for entry in projection.transcript {
            let node = entry.node
            if let answer = entry.answer {
                if answer.skipped {
                    deferredVariables.append(deferredVariable(node: node, wasSkipped: true, state: state))
                    continue
                }
                guard node.authority == .userDecision,
                      let questionText = node.text,
                      let variableID = node.variableID else {
                    continue
                }
                let option = answer.selectedOptionID.flatMap { optionID in
                    node.options.first(where: { $0.id == optionID })
                }
                // Typed words that only name a choice ("Yes") mean that
                // choice, whole: its effect tells the writer what it means.
                let typed = normalizedNonempty(answer.freeText)
                let named = typed.flatMap { words in
                    node.options.first { Self.namesOption(words, $0.label) }
                }
                // A newly answered version of the same question supersedes its carried answer.
                acceptedDecisions.removeAll { $0.questionText == questionText }
                acceptedDecisions.append(ComposerInterviewAcceptedDecision(
                    nodeID: node.id,
                    variableID: variableID,
                    questionText: questionText,
                    selectedOptionID: option?.id,
                    selectedOptionLabel: option?.label,
                    rawFreeText: typed,
                    draftEffects: Self.effects(of: option, named: named, typed: typed),
                    completesChoice: typed != nil && option?.kind == .authorWords ? true : nil
                ))
            } else if let grounding = entry.grounding,
                      let questionText = node.text,
                      let variableID = node.variableID {
                let answerText = normalizedNonempty(grounding.answerText)
                    ?? grounding.selectedOptionID.flatMap { optionID in
                        node.options.first(where: { $0.id == optionID })?.label
                    }
                    ?? ""
                evidenceFacts.append(ComposerInterviewEvidenceFact(
                    nodeID: node.id,
                    variableID: variableID,
                    questionText: questionText,
                    selectedOptionID: grounding.selectedOptionID,
                    answerText: answerText,
                    citations: grounding.citations
                ))
            }
        }

        let deferredNodeIDs = Set(deferredVariables.map(\.nodeID))
        let graphNodes = (state.baseProtocol.nodes + state.acceptedPatches.flatMap(\.nodes))
            .reduce(into: [String: ComposerInterviewNode]()) { $0[$1.id] = $1 }
        for nodeID in projection.unresolvedReachableNodeIDs
        where !deferredNodeIDs.contains(nodeID) {
            guard let node = graphNodes[nodeID], node.kind == .question else { continue }
            deferredVariables.append(deferredVariable(node: node, wasSkipped: false, state: state))
        }

        let digest = acceptedDecisionDigest(acceptedDecisions)
        return ComposerInterviewDraftInput(
            framing: framing,
            acceptedDecisions: acceptedDecisions,
            evidenceFacts: evidenceFacts,
            deferredVariables: deferredVariables,
            selectedSourceIDs: selectedSources.map(\.id),
            draftGuidance: draftGuidance,
            acceptedDecisionDigest: digest,
            acceptedDecisionDigestFingerprint: sha256Hex(digest),
            replyContext: framing == .reply ? state.replyContext : nil
        )
    }

    private static func deferredVariable(
        node: ComposerInterviewNode,
        wasSkipped: Bool,
        state: ComposerInterviewState
    ) -> ComposerInterviewDeferredVariable {
        ComposerInterviewDeferredVariable(
            nodeID: node.id,
            variableID: node.variableID ?? node.id,
            questionText: node.text ?? node.id,
            wasSkipped: wasSkipped,
            anchorQuote: state.replyContext?.questions.first { $0.id == node.id }?.anchorQuote,
            earlierAnswer: state.replyContext?.questions.first { $0.id == node.id }?.earlierAnswer
        )
    }

    private static func acceptedDecisionDigest(
        _ decisions: [ComposerInterviewAcceptedDecision]
    ) -> String {
        decisions.map { decision in
            let fields = [
                decision.nodeID,
                decision.variableID,
                decision.selectedOptionID ?? "",
                normalizedComparisonText(decision.rawFreeText ?? ""),
            ]
            return fields.map { "\($0.utf8.count):\($0)" }.joined()
        }.joined(separator: "\n")
    }

    /// What the answer tells the writer beyond the author's words: the
    /// choice's effect when it was picked or its label typed; for an open
    /// choice the author's words complete ("No", then their answer now),
    /// what the choice means followed by those words. Typed words that say
    /// more on any other choice are the answer alone.
    private static func effects(of option: ComposerInterviewOption?, named: ComposerInterviewOption?,
                                typed: String?) -> [String] {
        guard let typed else { return option?.draftEffects ?? [] }
        if let named { return named.draftEffects.filter { !namesOption($0, named.label) } }
        guard let option, option.kind == .authorWords,
              let meaning = option.draftEffects.first(where: { !namesOption($0, option.label) }) else { return [] }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unspaced scripts join sentences without a space.
        let unspaced = [meaning.last, words.first].contains { character in
            character.map { ComposerDraftEvidence.isUnspacedLetter($0) || "。！？".contains($0) } ?? false
        }
        return [meaning + (unspaced ? "" : " ") + words]
    }

    /// Whether typed words are only an option's label ("yes", "Yes.", "はい。").
    static func namesOption(_ words: String, _ label: String) -> Bool {
        func folded(_ text: String) -> String {
            text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！、,")))
                .lowercased()
        }
        let typed = folded(words)
        return !typed.isEmpty && typed == folded(label)
    }

    private static func normalizedNonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum ComposerInterviewDecisionLineCoding {
    public static func decode(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public static func encode(_ lines: [String]) -> String? {
        guard !lines.isEmpty,
              let data = try? JSONEncoder().encode(lines) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
