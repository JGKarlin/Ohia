import Foundation
import OhiaCore
import os

private let composerInterviewRepairSignposter = OSSignposter(
    subsystem: "org.jgkarlin.Ohia",
    category: "questionInterview"
)

public enum ComposerInterviewRepairRequirement: Sendable, Equatable {
    case notRequired
    case required
    case incompleteRequiredDetail
}

public struct ComposerInterviewRepairIdentity: Sendable, Equatable {
    public let generationEpoch: Int
    public let protocolFingerprint: String
    public let answeredPrefixFingerprint: String
    public let triggerAnswerFingerprint: String

    public init(
        generationEpoch: Int,
        protocolFingerprint: String,
        answeredPrefixFingerprint: String,
        triggerAnswerFingerprint: String
    ) {
        self.generationEpoch = generationEpoch
        self.protocolFingerprint = protocolFingerprint
        self.answeredPrefixFingerprint = answeredPrefixFingerprint
        self.triggerAnswerFingerprint = triggerAnswerFingerprint
    }
}

public struct ComposerInterviewRepairRequest: Sendable, Equatable {
    public let contextPack: ComposerContextPack
    public let plan: ComposerInterviewPlan
    public let acceptedPatches: [ComposerInterviewPatch]
    public let answeredPrefix: [ComposerInterviewAnswer]
    public let priorGroundings: [QuestionGrounding]
    public let resolvedVariableIDs: Set<String>
    public let protocolFingerprint: String
    public let answeredPrefixFingerprint: String
    /// The committed answer whose typed words this repair reads. On a choice
    /// question the repair first decides which choice they mean; where the
    /// interview continues follows from that decision, not from the pick.
    public let triggerAnswer: ComposerInterviewAnswer
    public let remainingTotalQuestionNodes: Int
    public let remainingPathQuestionNodes: Int
    /// Replacement questions use the same reading language as the plan.
    public let questionLanguage: SummarizationTargetLanguage

    public init(
        contextPack: ComposerContextPack,
        plan: ComposerInterviewPlan,
        acceptedPatches: [ComposerInterviewPatch],
        answeredPrefix: [ComposerInterviewAnswer],
        priorGroundings: [QuestionGrounding],
        resolvedVariableIDs: Set<String>,
        protocolFingerprint: String,
        answeredPrefixFingerprint: String,
        triggerAnswer: ComposerInterviewAnswer,
        remainingTotalQuestionNodes: Int,
        remainingPathQuestionNodes: Int,
        questionLanguage: SummarizationTargetLanguage
    ) {
        self.contextPack = contextPack
        self.plan = plan
        self.acceptedPatches = acceptedPatches
        self.answeredPrefix = answeredPrefix
        self.priorGroundings = priorGroundings
        self.resolvedVariableIDs = resolvedVariableIDs
        self.protocolFingerprint = protocolFingerprint
        self.answeredPrefixFingerprint = answeredPrefixFingerprint
        self.triggerAnswer = triggerAnswer
        self.remainingTotalQuestionNodes = remainingTotalQuestionNodes
        self.remainingPathQuestionNodes = remainingPathQuestionNodes
        self.questionLanguage = questionLanguage
    }

    public var identity: ComposerInterviewRepairIdentity {
        ComposerInterviewRepairIdentity(
            generationEpoch: plan.generationEpoch,
            protocolFingerprint: protocolFingerprint,
            answeredPrefixFingerprint: answeredPrefixFingerprint,
            triggerAnswerFingerprint: triggerAnswer.answerFingerprint
        )
    }
}

public enum ComposerInterviewRepairOutcome: String, Codable, Sendable, Equatable {
    case unchanged
    case applied
    case failed
}

public enum ComposerInterviewRepairValidationOutcome: String, Codable, Sendable, Equatable {
    case notRun = "not_run"
    case unchanged
    case valid
    case invalid
}

public enum ComposerInterviewRepairInfrastructureOutcome: String, Codable, Sendable, Equatable {
    case completed
    case modelNotLoaded = "model_not_loaded"
    case cancelled
    case stale
    case failed
}

public struct ComposerInterviewRepairMetrics: Codable, Sendable, Equatable {
    public let duration: TimeInterval
    public let generatedTokenCount: Int?
    public let visibleTokenCount: Int?
    public let thinkingTokenCount: Int?
    public let replacementNodeCount: Int
    public let validationOutcome: ComposerInterviewRepairValidationOutcome
    public let validationAttemptCount: Int
    public let attemptNumber: Int
    public let infrastructureOutcome: ComposerInterviewRepairInfrastructureOutcome
    public let repairCallCount: Int

    public init(
        duration: TimeInterval,
        generatedTokenCount: Int?,
        visibleTokenCount: Int?,
        thinkingTokenCount: Int?,
        replacementNodeCount: Int,
        validationOutcome: ComposerInterviewRepairValidationOutcome,
        validationAttemptCount: Int,
        attemptNumber: Int,
        infrastructureOutcome: ComposerInterviewRepairInfrastructureOutcome,
        repairCallCount: Int
    ) {
        self.duration = duration
        self.generatedTokenCount = generatedTokenCount
        self.visibleTokenCount = visibleTokenCount
        self.thinkingTokenCount = thinkingTokenCount
        self.replacementNodeCount = replacementNodeCount
        self.validationOutcome = validationOutcome
        self.validationAttemptCount = validationAttemptCount
        self.attemptNumber = attemptNumber
        self.infrastructureOutcome = infrastructureOutcome
        self.repairCallCount = repairCallCount
    }
}

public struct ComposerInterviewRepairResult: Sendable, Equatable {
    public let outcome: ComposerInterviewRepairOutcome
    public let patch: ComposerInterviewPatch?
    /// On a choice question, what the typed words mean. Nil for a free-text
    /// question, and when the response did not say: the words stay unread,
    /// which leaves every choice's follow-up questions open, never the pick's.
    public let typedReading: ComposerInterviewTypedReading?
    public let metrics: ComposerInterviewRepairMetrics

    public init(
        outcome: ComposerInterviewRepairOutcome,
        patch: ComposerInterviewPatch?,
        typedReading: ComposerInterviewTypedReading? = nil,
        metrics: ComposerInterviewRepairMetrics
    ) {
        self.outcome = outcome
        self.patch = patch
        self.typedReading = typedReading
        self.metrics = metrics
    }
}

public final class ComposerInterviewRepairer: Sendable {
    public static let maximumGeneratedTokens = 2_048
    public static let maximumOutputBytes = 128 * 1_024
    public static let maximumPromptBytes = 256 * 1_024

    private let engine: any TrainingEngine
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private let displayLanguageGuard: DisplayLanguageGuard?
    private let metricsHandler: @Sendable (ComposerInterviewRepairMetrics) -> Void

    public init(
        engine: any TrainingEngine,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        displayLanguageGuard: DisplayLanguageGuard? = nil,
        metricsHandler: @escaping @Sendable (ComposerInterviewRepairMetrics) -> Void = { _ in }
    ) {
        self.engine = engine
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
        self.displayLanguageGuard = displayLanguageGuard
        self.metricsHandler = metricsHandler
    }

    public static func requirement(
        for answer: ComposerInterviewAnswer,
        in node: ComposerInterviewNode
    ) -> ComposerInterviewRepairRequirement {
        let hasFreeText = answer.freeText?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false
        // Words completing a choice in the author's words ("No", then their
        // answer now) mean that choice: there is nothing to read, and the
        // questions still to come stay as planned.
        if hasFreeText, let selectedOptionID = answer.selectedOptionID,
           node.options.first(where: { $0.id == selectedOptionID })?.kind == .authorWords {
            return .notRequired
        }
        if hasFreeText {
            return .required
        }
        guard let selectedOptionID = answer.selectedOptionID,
              let kind = node.options.first(where: { $0.id == selectedOptionID })?.kind,
              kind == .otherUnanticipated || kind == .authorWords else {
            return .notRequired
        }
        return .incompleteRequiredDetail
    }

    public func repair(
        _ request: ComposerInterviewRepairRequest,
        attemptNumber: Int = 1,
        cancellation: GenerationCancellation? = nil
    ) throws -> ComposerInterviewRepairResult {
        guard let result = try performRepair(
            request,
            attemptNumber: attemptNumber,
            cancellation: cancellation,
            currentIdentity: nil
        ) else {
            preconditionFailure("A repair without an identity guard cannot become stale")
        }
        return result
    }

    public func repairIfCurrent(
        _ request: ComposerInterviewRepairRequest,
        attemptNumber: Int = 1,
        cancellation: GenerationCancellation? = nil,
        currentIdentity: @escaping @Sendable () -> ComposerInterviewRepairIdentity
    ) throws -> ComposerInterviewRepairResult? {
        try performRepair(
            request,
            attemptNumber: attemptNumber,
            cancellation: cancellation,
            currentIdentity: currentIdentity
        )
    }

    private func performRepair(
        _ request: ComposerInterviewRepairRequest,
        attemptNumber: Int,
        cancellation: GenerationCancellation?,
        currentIdentity: (@Sendable () -> ComposerInterviewRepairIdentity)?
    ) throws -> ComposerInterviewRepairResult? {
        let startedAt = Date()
        let interval = composerInterviewRepairSignposter.beginInterval(
            "repair",
            id: composerInterviewRepairSignposter.makeSignpostID(),
            "attempt=\(attemptNumber)"
        )
        let activityToken = modelActivityStatusPublisher?.begin(
            .questioning,
            source: "composer-interview-repairer"
        )
        defer {
            if let activityToken {
                modelActivityStatusPublisher?.end(activityToken)
            }
        }

        var generatedTokenCount: Int?
        var visibleTokenCount: Int?
        var thinkingTokenCount: Int?
        var repairCallCount = 0

        func finish(
            validationOutcome: ComposerInterviewRepairValidationOutcome,
            validationAttemptCount: Int,
            replacementNodeCount: Int,
            infrastructureOutcome: ComposerInterviewRepairInfrastructureOutcome
        ) -> ComposerInterviewRepairMetrics {
            let metrics = ComposerInterviewRepairMetrics(
                duration: max(0, Date().timeIntervalSince(startedAt)),
                generatedTokenCount: generatedTokenCount,
                visibleTokenCount: visibleTokenCount,
                thinkingTokenCount: thinkingTokenCount,
                replacementNodeCount: replacementNodeCount,
                validationOutcome: validationOutcome,
                validationAttemptCount: validationAttemptCount,
                attemptNumber: max(1, attemptNumber),
                infrastructureOutcome: infrastructureOutcome,
                repairCallCount: repairCallCount
            )
            metricsHandler(metrics)
            let generatedCount = metrics.generatedTokenCount ?? -1
            let visibleCount = metrics.visibleTokenCount ?? -1
            let thinkingCount = metrics.thinkingTokenCount ?? -1
            composerInterviewRepairSignposter.endInterval(
                "repair",
                interval,
                "duration=\(metrics.duration) generated=\(generatedCount) visible=\(visibleCount) thinking=\(thinkingCount) nodes=\(metrics.replacementNodeCount) validation=\(metrics.validationOutcome.rawValue) validationAttempts=\(metrics.validationAttemptCount) attempt=\(metrics.attemptNumber) infrastructure=\(metrics.infrastructureOutcome.rawValue) repairCalls=\(metrics.repairCallCount)"
            )
            return metrics
        }

        do {
            try cancellation?.checkCancellation()
            if let currentIdentity, currentIdentity() != request.identity {
                _ = finish(
                    validationOutcome: .notRun,
                    validationAttemptCount: 0,
                    replacementNodeCount: 0,
                    infrastructureOutcome: .stale
                )
                return nil
            }

            guard let trigger = Self.triggerNode(for: request) else {
                let metrics = finish(
                    validationOutcome: .invalid,
                    validationAttemptCount: 0,
                    replacementNodeCount: 0,
                    infrastructureOutcome: .completed
                )
                return ComposerInterviewRepairResult(
                    outcome: .failed,
                    patch: nil,
                    metrics: metrics
                )
            }

            let prompt = Self.prompt(for: request, trigger: trigger)
            guard prompt.utf8.count <= Self.maximumPromptBytes else {
                let metrics = finish(
                    validationOutcome: .invalid,
                    validationAttemptCount: 0,
                    replacementNodeCount: 0,
                    infrastructureOutcome: .completed
                )
                return ComposerInterviewRepairResult(
                    outcome: .failed,
                    patch: nil,
                    metrics: metrics
                )
            }

            repairCallCount = 1
            let generation = try generate(
                prompt: prompt,
                cancellation: cancellation
            )
            try cancellation?.checkCancellation()

            generatedTokenCount = generation.result?.diagnostics?.generatedTokenCount
            if let tokenCounter = engine as? any PromptTokenCounting {
                visibleTokenCount = tokenCounter.promptTokenCount(generation.text)
                if let reasoning = generation.result?.reasoningContent, !reasoning.isEmpty {
                    thinkingTokenCount = tokenCounter.promptTokenCount(reasoning)
                } else {
                    thinkingTokenCount = 0
                }
            }

            if let currentIdentity, currentIdentity() != request.identity {
                _ = finish(
                    validationOutcome: .notRun,
                    validationAttemptCount: 0,
                    replacementNodeCount: 0,
                    infrastructureOutcome: .stale
                )
                return nil
            }

            let decoded = Self.decodeAndValidate(generation.text, request: request, trigger: trigger)
            try cancellation?.checkCancellation()
            if let currentIdentity, currentIdentity() != request.identity {
                _ = finish(
                    validationOutcome: .notRun,
                    validationAttemptCount: 0,
                    replacementNodeCount: 0,
                    infrastructureOutcome: .stale
                )
                return nil
            }
            switch decoded.outcome {
            case .unchanged:
                let metrics = finish(
                    validationOutcome: .unchanged,
                    validationAttemptCount: 1,
                    replacementNodeCount: 0,
                    infrastructureOutcome: .completed
                )
                return ComposerInterviewRepairResult(
                    outcome: .unchanged,
                    patch: nil,
                    typedReading: decoded.typedReading,
                    metrics: metrics
                )
            case .applied(var patch):
                if let displayLanguageGuard {
                    patch.nodes = patch.nodes.displayingLanguage(
                        using: displayLanguageGuard,
                        targetLanguage: request.questionLanguage,
                        source: DisplayLanguageGuard.Source(
                            languageHint: nil,
                            context: String(request.contextPack.anchorText.prefix(1_200)),
                            messageID: nil,
                            accountID: nil,
                            preservesQuotedText: true
                        ),
                        cancellation: cancellation ?? GenerationCancellation()
                    )
                    try cancellation?.checkCancellation()
                    if let currentIdentity, currentIdentity() != request.identity {
                        _ = finish(
                            validationOutcome: .notRun,
                            validationAttemptCount: 0,
                            replacementNodeCount: 0,
                            infrastructureOutcome: .stale
                        )
                        return nil
                    }
                }
                let metrics = finish(
                    validationOutcome: .valid,
                    validationAttemptCount: 1,
                    replacementNodeCount: patch.nodes.count,
                    infrastructureOutcome: .completed
                )
                return ComposerInterviewRepairResult(
                    outcome: .applied,
                    patch: patch,
                    typedReading: decoded.typedReading,
                    metrics: metrics
                )
            case .failed:
                let metrics = finish(
                    validationOutcome: .invalid,
                    validationAttemptCount: 1,
                    replacementNodeCount: 0,
                    infrastructureOutcome: .completed
                )
                // A choice the response did name still decides the route even
                // when its replacement questions were unusable.
                return ComposerInterviewRepairResult(
                    outcome: .failed,
                    patch: nil,
                    typedReading: decoded.typedReading,
                    metrics: metrics
                )
            }
        } catch {
            let infrastructureOutcome: ComposerInterviewRepairInfrastructureOutcome
            if error is CancellationError {
                infrastructureOutcome = .cancelled
            } else if case TrainingEngineError.modelNotLoaded = error {
                infrastructureOutcome = .modelNotLoaded
            } else {
                infrastructureOutcome = .failed
            }
            _ = finish(
                validationOutcome: .notRun,
                validationAttemptCount: 0,
                replacementNodeCount: 0,
                infrastructureOutcome: infrastructureOutcome
            )
            throw error
        }
    }

    private struct GenerationPayload {
        let text: String
        let result: GenerationResult?
    }

    static func reviewGuidance(for request: ComposerInterviewRepairRequest) -> String {
        let nodes = request.plan.baseProtocol.nodes + request.acceptedPatches.flatMap(\.nodes)
        let answers = request.answeredPrefix.compactMap { answer -> String? in
            guard !answer.skipped, let node = nodes.first(where: { $0.id == answer.nodeID }) else { return nil }
            let value = answer.freeText.flatMap { $0.isEmpty ? nil : $0 }
                ?? node.options.first { $0.id == answer.selectedOptionID }?.label
            return value.map { "Question: \(node.text ?? "")\nUser answer: \($0)" }
        }
        return ([request.plan.replyContext?.draftGuidance].compactMap { $0 } + answers)
            .joined(separator: "\n")
    }

    private func generate(
        prompt: String,
        cancellation: GenerationCancellation?
    ) throws -> GenerationPayload {
        if let worker = engine as? WorkerGenerationEngine {
            let result = try worker.generateResult(prompt: prompt, maxTokens: Self.maximumGeneratedTokens,
                cancellation: cancellation ?? GenerationCancellation(), activityKind: .questioning, personalization: .base)
            return GenerationPayload(text: result.text, result: result)
        }
        let result = try PrefixCachedGeneration.generateResult(
            engine: engine,
            prompt: prompt,
            maxTokens: Self.maximumGeneratedTokens,
            cancellation: cancellation ?? GenerationCancellation(),
            personalization: .base,
            sampling: ComposerInterviewPlanner.generationSampling
        )
        return GenerationPayload(text: result.text, result: result)
    }

    private enum DecodedOutcome {
        case unchanged
        case applied(ComposerInterviewPatch)
        case failed
    }

    private struct Decoded {
        let outcome: DecodedOutcome
        let typedReading: ComposerInterviewTypedReading?
    }

    /// What "m" says the typed words mean on a choice question.
    enum TypedChoice: Equatable {
        case choice(String)
        case noChoice
    }

    /// The choice "m" names on `trigger`: its 1-based number (0 for none of
    /// the choices), as a JSON number or a string of decimal digits in any
    /// script, or else one choice's exact id or label. Anything else names
    /// nothing.
    static func typedChoice(
        _ reference: ChoiceReference?,
        on trigger: ComposerInterviewNode
    ) -> TypedChoice? {
        guard let reference, trigger.responseType == .multipleChoice else { return nil }
        let options = trigger.options
        func numbered(_ number: Int) -> TypedChoice? {
            if number == 0 { return .noChoice }
            return options.indices.contains(number - 1) ? .choice(options[number - 1].id) : nil
        }
        func named(_ text: String) -> TypedChoice? {
            if let option = options.first(where: { $0.id == text }) { return .choice(option.id) }
            let key = choiceComparisonKey(text)
            let matches = options.filter { choiceComparisonKey($0.label) == key }
            return matches.count == 1 ? .choice(matches[0].id) : nil
        }
        switch reference {
        case .number(let number):
            return numbered(number) ?? named(String(number))
        case .text(let raw):
            let text = raw.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = decimalValue(text), let choice = numbered(number) { return choice }
            return named(text)
        }
    }

    /// A short run of decimal digits in any script ("2", "２", "٢", "२").
    private static func decimalValue(_ text: String) -> Int? {
        guard (1...3).contains(text.count) else { return nil }
        var value = 0
        for character in text {
            guard character.isNumber, let digit = character.wholeNumberValue,
                  (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func choiceComparisonKey(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The choice whose exact label the typed words open with, followed by
    /// a separator (after any spaces) or nothing more: "Yes, but only in the
    /// afternoon.", "Yes — happy to.", "はい、ただし午後のみです。", "No." The
    /// author named that choice, so no model reading overrides it. A label run
    /// on into a word ("No problem") or joined to one ("No-one", "Yes/no")
    /// names nothing. The longest label the words open with decides: when it
    /// runs on ("Yes, with changes to the travel line" against "Yes" and "Yes,
    /// with changes"), the words name nothing rather than the shorter label
    /// inside it. A label that ends in punctuation ("Yes.") needs no separator.
    static func leadingChoice(
        of typedWords: String?,
        on trigger: ComposerInterviewNode
    ) -> String? {
        guard trigger.responseType == .multipleChoice, let typedWords else { return nil }
        let text = trimmedForLabelMatching(typedWords)
        var longest: (optionID: String?, length: Int)?
        for option in trigger.options {
            let label = trimmedForLabelMatching(option.label)
            guard !label.isEmpty,
                  let range = text.range(of: label, options: [.anchored, .caseInsensitive]) else {
                continue
            }
            let length = text.distance(from: text.startIndex, to: range.upperBound)
            let named = endsLabel(label, before: text[range.upperBound...]) ? option.id : nil
            if let current = longest {
                if length < current.length { continue }
                // Two labels as long as each other: the words name neither.
                longest = (length == current.length && current.optionID != named) ? (nil, length) : (named, length)
            } else {
                longest = (named, length)
            }
        }
        return longest?.optionID
    }

    /// Characters that close a choice's label: sentence punctuation in any
    /// script, closing brackets, and a dash. A hyphen, en dash, slash or
    /// apostrophe right after a label joins it to a word instead.
    private static let labelSeparators: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "\u{2026}", "\u{2014}", ")", "]",
        "\u{3001}", "\u{3002}", "\u{300D}", "\u{300F}", "\u{FF09}",
        "\u{060C}", "\u{061B}", "\u{061F}", "\u{06D4}", "\u{0964}", "\u{0965}",
    ]

    /// After spaces, a hyphen or en dash separates too ("Yes - happy to").
    private static let spacedLabelSeparators: Set<Character> = ["-", "\u{2013}"]

    private static func endsLabel(_ label: String, before rest: Substring) -> Bool {
        guard let next = rest.first else { return true }
        if let last = label.last, last.isPunctuation { return true }
        if labelSeparators.contains(next) { return true }
        guard next.isWhitespace,
              let separator = rest.first(where: { !$0.isWhitespace }) else { return false }
        return labelSeparators.contains(separator) || spacedLabelSeparators.contains(separator)
    }

    /// Compatibility-mapped (full-width ＹＥＳ，→ YES,) with surrounding spaces
    /// and invisible direction or format marks removed.
    private static func trimmedForLabelMatching(_ text: String) -> String {
        let mapped = text.precomposedStringWithCompatibilityMapping
        func isInvisible(_ character: Character) -> Bool {
            character.isWhitespace || character.unicodeScalars.allSatisfy {
                $0.properties.generalCategory == .format
            }
        }
        guard let first = mapped.firstIndex(where: { !isInvisible($0) }),
              let last = mapped.lastIndex(where: { !isInvisible($0) }) else { return "" }
        return String(mapped[first...last])
    }

    /// The remaining questions that ask only after some answers to this
    /// question: those conditioned on it.
    private static func dependentConditions(
        request: ComposerInterviewRepairRequest,
        trigger: ComposerInterviewNode
    ) -> [ComposerInterviewCondition] {
        remainingNodes(for: request, trigger: trigger).compactMap { node in
            node.condition.flatMap { $0.nodeID == trigger.id ? $0 : nil }
        }
    }

    /// Whether a reading of "none of the choices" would pass over questions
    /// that depend on this answer: those conditioned on one of its choices
    /// that its open "Other" choice (if any) does not meet.
    private static func noChoicePassesOverFollowUps(
        request: ComposerInterviewRepairRequest,
        trigger: ComposerInterviewNode
    ) -> Bool {
        let otherID = trigger.options.first(where: { $0.kind == .otherUnanticipated })?.id
        return dependentConditions(request: request, trigger: trigger).contains { condition in
            otherID.map { !condition.optionIDs.contains($0) } ?? true
        }
    }

    private static func decodeAndValidate(
        _ text: String,
        request: ComposerInterviewRepairRequest,
        trigger: ComposerInterviewNode
    ) -> Decoded {
        // Typed words that open with a choice's label mean that choice.
        let leadingReading = leadingChoice(of: request.triggerAnswer.freeText, on: trigger)
            .map { ComposerInterviewTypedReading(optionID: $0) }
        let failed = Decoded(outcome: .failed, typedReading: leadingReading)
        guard text.utf8.count <= maximumOutputBytes,
              let data = text.data(using: .utf8),
              let response = try? JSONDecoder().decode(CompactResponse.self, from: data) else {
            return failed
        }

        // Typed words override the picked choice, so a choice question's
        // repair must say which choice they mean. Without that the words
        // stay unread, and the questions of every choice stay open.
        var modelReading: ComposerInterviewTypedReading?
        if trigger.responseType == .multipleChoice {
            switch typedChoice(response.typedChoice, on: trigger) {
            case .choice(let optionID): modelReading = ComposerInterviewTypedReading(optionID: optionID)
            case .noChoice: modelReading = ComposerInterviewTypedReading(optionID: nil)
            case nil: modelReading = nil
            }
        }
        var typedReading = leadingReading ?? modelReading
        // The local model's typical misreading is "none of the choices" for
        // words that do mean one, together with ending the questions. When
        // that reading would pass over questions that depend on the answer,
        // the words stay unread instead, so those questions are asked (and
        // can be skipped) rather than silently dropped.
        if leadingReading == nil,
           typedReading == ComposerInterviewTypedReading(optionID: nil),
           noChoicePassesOverFollowUps(request: request, trigger: trigger) {
            typedReading = nil
        }
        // A continuation the model planned for another reading does not fit
        // this one: the validated plan stands, routed by this reading.
        if let modelReading, typedReading != modelReading {
            return Decoded(outcome: .unchanged, typedReading: typedReading)
        }
        let leavesChoiceUnread = trigger.responseType == .multipleChoice && typedReading == nil
        // Where the interview continues once the typed words stand for that
        // reading. Any replacement replaces this continuation, not the pick's.
        let decided = request.triggerAnswer.recordingRepair(
            request.triggerAnswer.repairDisposition,
            typedReading: typedReading
        )
        guard let continuationNodeID = ComposerInterviewExecutor.continuationNodeID(
            after: decided,
            to: trigger
        ) else {
            return failed
        }
        let failedKeepingReading = Decoded(outcome: .failed, typedReading: typedReading)

        switch response.outcome {
        case "unchanged":
            guard !leavesChoiceUnread,
                  response.replacementEntryNodeID == nil,
                  !response.hasMalformedNodes,
                  response.nodes == nil || response.nodes?.isEmpty == true else {
                return failedKeepingReading
            }
            return Decoded(outcome: .unchanged, typedReading: typedReading)
        case "replace_continuation":
            guard let replacementEntryNodeID = response.replacementEntryNodeID else {
                return failedKeepingReading
            }
            // A replacement that enters one of the remaining questions replaces
            // nothing: the model restated the plan, typically repeating those
            // questions under their own ids. The validated plan stands, and the
            // reading decides which of its questions are asked.
            let remainingQuestionIDs = Set(remainingNodes(for: request, trigger: trigger)
                .filter { $0.kind == .question }.map(\.id))
            if remainingQuestionIDs.contains(replacementEntryNodeID) {
                guard !leavesChoiceUnread else { return failed }
                return Decoded(outcome: .unchanged, typedReading: typedReading)
            }
            guard !response.hasMalformedNodes,
                  let compactNodes = response.nodes,
                  let nodes = try? compactNodes.map({ try $0.node() }) else {
                return failedKeepingReading
            }
            // Ending the interview needs no reading of the choice unless a
            // remaining question depends on it: then the words stay unread
            // and those questions are asked rather than silently dropped.
            let endsInterview = nodes.isEmpty
                && replacementEntryNodeID == request.plan.baseProtocol.terminalNodeID
            if leavesChoiceUnread, endsInterview,
               !dependentConditions(request: request, trigger: trigger).isEmpty {
                return Decoded(outcome: .unchanged, typedReading: nil)
            }
            guard !leavesChoiceUnread || endsInterview else { return failed }
            let candidate = ComposerInterviewPatch(
                id: patchID(for: request.triggerAnswer.answerFingerprint),
                triggerNodeID: request.triggerAnswer.nodeID,
                triggerAnswerFingerprint: request.triggerAnswer.answerFingerprint,
                replacedContinuationNodeID: continuationNodeID,
                replacementEntryNodeID: replacementEntryNodeID,
                nodes: nodes
            )
            guard let validated = try? ComposerInterviewProtocolValidator.validate(
                patch: candidate,
                context: validationContext(for: request, continuationNodeID: continuationNodeID)
            ) else {
                return failedKeepingReading
            }
            if !nodes.isEmpty, request.plan.replyContext != nil {
                guard let preparation = response.context,
                      let review = try? ComposerReplyContextReview.resolve(preparation,
                        anchor: request.contextPack.anchorText, sources: request.contextPack.sources,
                        guidance: reviewGuidance(for: request), questions: nodes,
                        subject: request.plan.replyContext?.subject ?? ""),
                      review.questions.allSatisfy({ $0.disposition == .unresolved }) else {
                    return failedKeepingReading
                }
            }
            return Decoded(outcome: .applied(validated), typedReading: typedReading)
        default:
            return failedKeepingReading
        }
    }

    private static func validationContext(
        for request: ComposerInterviewRepairRequest,
        continuationNodeID: String
    ) -> ComposerInterviewPatchValidationContext {
        let allNodes = request.plan.baseProtocol.nodes
            + request.acceptedPatches.flatMap(\.nodes)
        let nodeMap = allNodes.reduce(into: [String: ComposerInterviewNode]()) {
            $0[$1.id] = $1
        }
        let answeredNodeIDs = Set(request.answeredPrefix.map(\.nodeID))
        let existingQuestionNodeCount = Set(
            allNodes.lazy.filter { $0.kind == .question }.map(\.id)
        ).count
        let answeredVariableIDs = request.resolvedVariableIDs.union(
            request.answeredPrefix.compactMap { nodeMap[$0.nodeID]?.variableID }
        )
        return ComposerInterviewPatchValidationContext(
            baseProtocol: request.plan.baseProtocol,
            acceptedPatches: request.acceptedPatches,
            answeredNodeIDs: answeredNodeIDs,
            answeredVariableIDs: answeredVariableIDs,
            requestProtocolFingerprint: request.protocolFingerprint,
            currentProtocolFingerprint: request.protocolFingerprint,
            requestGenerationEpoch: request.plan.generationEpoch,
            currentGenerationEpoch: request.plan.generationEpoch,
            requestAnsweredPrefixFingerprint: request.answeredPrefixFingerprint,
            currentAnsweredPrefixFingerprint: request.answeredPrefixFingerprint,
            expectedTriggerNodeID: request.triggerAnswer.nodeID,
            expectedTriggerAnswerFingerprint: request.triggerAnswer.answerFingerprint,
            expectedContinuationNodeID: continuationNodeID,
            maximumTotalQuestionNodes: existingQuestionNodeCount
                + max(0, request.remainingTotalQuestionNodes),
            maximumPathQuestionNodes: answeredNodeIDs.count
                + max(0, request.remainingPathQuestionNodes)
        )
    }

    /// The answered question whose typed words the repair reads, when the
    /// request is coherent: its answer is the last of the answered prefix and
    /// carries typed words, and any pick names one of its choices.
    private static func triggerNode(
        for request: ComposerInterviewRepairRequest
    ) -> ComposerInterviewNode? {
        let allNodes = request.plan.baseProtocol.nodes
            + request.acceptedPatches.flatMap(\.nodes)
        let nodeMap = allNodes.reduce(into: [String: ComposerInterviewNode]()) {
            $0[$1.id] = $1
        }
        let answer = request.triggerAnswer
        guard answer.nodeID == request.answeredPrefix.last?.nodeID,
              answer.answerFingerprint == request.answeredPrefix.last?.answerFingerprint,
              !answer.skipped,
              let node = nodeMap[answer.nodeID],
              node.kind == .question,
              requirement(for: answer, in: node) == .required else {
            return nil
        }
        switch node.responseType {
        case .multipleChoice:
            if let selectedOptionID = answer.selectedOptionID,
               !node.options.contains(where: { $0.id == selectedOptionID }) {
                return nil
            }
            return node
        case .freeText:
            return answer.selectedOptionID == nil ? node : nil
        case nil:
            return nil
        }
    }

    private static func prompt(
        for request: ComposerInterviewRepairRequest,
        trigger: ComposerInterviewNode
    ) -> String {
        let remaining = remainingNodes(for: request, trigger: trigger)
        let choiceQuestion = trigger.responseType == .multipleChoice
        let choiceField = choiceQuestion ? #""m":M,"# : ""
        return """
        You are reading one answer the author just committed in an already validated email-drafting interview, and checking whether it changes the unanswered portion of the interview. The author's typed words are authoritative: they replace any choice the author picked, and when they contradict that choice, the typed words decide. Never rewrite, reinterpret, or delete the answered prefix. Return exactly one minified JSON object and no prose.
        \(choiceQuestion ? typedChoiceInstructions(for: request, trigger: trigger) : "")
        Return {\(choiceField)"o":"unchanged"} when the remaining questions still fit the answer.
        If the answer makes every remaining question unnecessary, return {\(choiceField)"o":"replace_continuation","e":"\(request.plan.baseProtocol.terminalNodeID)","n":[]}. This ends questioning while preserving the answer. For example, declining a meeting makes questions about the meeting date and time unnecessary. Do not invent a follow-up merely to keep questioning. This terminal-only replacement is allowed even when remaining question capacity is zero.
        Otherwise return {\(choiceField)"o":"replace_continuation","e":"entry_node_id","n":[compact question nodes]}.
        A compact node uses i=id, v=variable, s=approach|detail, a=user_decision, q=question, r=multiple_choice|free_text, o=options, x=free-text answered route, z=skip route, w=impact. Repair-created questions resolve only user decisions; evidence grounding is complete and evidence_fact is forbidden. A compact option uses l=label, n=next node, optional k=other_unanticipated|unsure_need_to_check, and optional e=draft effect. Option IDs are derived locally. Emit question nodes only; route leaves to an allowed unanswered node from the supplied remaining questions. Stay within both remaining capacities.
        A question answered by picking (yes or no, accept or decline, or one of the proposed alternatives) uses r=multiple_choice with 2–4 short options. Write questions and option labels in \(request.questionLanguage.promptDescription).

        PROTOCOL INPUT FINGERPRINT: \(request.plan.inputFingerprint)
        PROTOCOL FINGERPRINT: \(request.protocolFingerprint)
        GENERATION EPOCH: \(request.plan.generationEpoch)
        ANSWERED PREFIX FINGERPRINT: \(request.answeredPrefixFingerprint)
        TRIGGER ANSWER FINGERPRINT: \(request.triggerAnswer.answerFingerprint)
        REMAINING TOTAL QUESTION CAPACITY: \(max(0, request.remainingTotalQuestionNodes))
        REMAINING PATH QUESTION CAPACITY: \(max(0, request.remainingPathQuestionNodes))

        If adding replacement questions to a reply with prepared context, include context alongside o/e/n in this same response; no later review is available. Account for every replacement question using supplied passage IDs. An unchanged or terminal-only result needs no context.
        \(ComposerReplyContextReview.preparationInstructions)
        APP-OWNED PASSAGE CATALOG:
        \(ComposerReplyContextReview.passageJSON(anchor: request.contextPack.anchorText, sources: request.contextPack.sources, guidance: reviewGuidance(for: request), subject: request.plan.replyContext?.subject ?? ""))

        ORIGINAL CONTEXT:
        \(request.contextPack.anchorText)
        \(request.contextPack.digest)

        The current email and explicit user answers define the reply's purpose. Historical sources provide context only. A sent reply can establish an already-communicated decision; do not reopen it unless the current message or user answer requires reconsideration. Historical uncertainty records are not proof that a question is open.

        IMMUTABLE PLAN JSON: \(encodedJSON(request.plan))
        ACCEPTED PATCH LINEAGE JSON: \(encodedJSON(request.acceptedPatches))
        ANSWERED PREFIX JSON: \(encodedJSON(request.answeredPrefix))
        PRIOR GROUNDINGS JSON: \(encodedJSON(request.priorGroundings))
        RESOLVED VARIABLE IDS JSON: \(encodedJSON(request.resolvedVariableIDs.sorted()))
        AUTHORITATIVE TRIGGER ANSWER JSON: \(encodedJSON(request.triggerAnswer))
        REMAINING UNANSWERED QUESTIONS JSON: \(encodedJSON(remaining))

        JSON:
        /no_think
        """
    }

    /// The decision a choice question's repair makes first: which choice the
    /// typed words mean. The app routes on that number, never on the pick.
    private static func typedChoiceInstructions(
        for request: ComposerInterviewRepairRequest,
        trigger: ComposerInterviewNode
    ) -> String {
        let choices = trigger.options.enumerated().map { index, option in
            "\(index + 1). \(encodedJSON(option.label)) [\(option.id)]"
        }.joined(separator: "\n")
        let picked = request.triggerAnswer.selectedOptionID.flatMap { selectedOptionID in
            trigger.options.firstIndex(where: { $0.id == selectedOptionID }).map { index in
                "\(index + 1). \(encodedJSON(trigger.options[index].label))"
            }
        } ?? "none"
        return """

        The answer is to a choice question, so first decide which choice the typed words mean. They may be in any language. Judge them by what they say, not by which choice was picked.
        QUESTION: \(encodedJSON(trigger.text ?? ""))
        CHOICES:
        \(choices)
        PICKED CHOICE: \(picked)
        TYPED WORDS: \(encodedJSON(request.triggerAnswer.freeText ?? ""))
        Every response starts with "m": the number of the choice the typed words mean, or 0 when they mean none of the choices. M below stands for that number. Decide "m" on its own: it is the choice the words mean even when they also answer or end the remaining questions. The app asks the remaining questions by "m": a remaining question whose condition has nodeID "\(trigger.id)" is asked only when the choice "m" names is one of its optionIDs. The remaining questions are already in the interview, so never repeat one in "n": "n" holds only new questions with new ids, and replacement questions may route only into remaining questions that follow the choice "m" names.

        """
    }

    /// The unanswered questions after the trigger, along every route it can
    /// take. Which of them are asked depends on the choice the typed words
    /// mean, so each is shown with its condition.
    private static func remainingNodes(
        for request: ComposerInterviewRepairRequest,
        trigger: ComposerInterviewNode
    ) -> [ComposerInterviewNode] {
        let allNodes = request.plan.baseProtocol.nodes
            + request.acceptedPatches.flatMap(\.nodes)
        let nodeMap = allNodes.reduce(into: [String: ComposerInterviewNode]()) {
            $0[$1.id] = $1
        }
        var visited: Set<String> = [trigger.id]
        var ordered: [ComposerInterviewNode] = []
        var queue = trigger.outgoingNodeIDs
        while let nodeID = queue.first {
            queue.removeFirst()
            guard visited.insert(nodeID).inserted, let node = nodeMap[nodeID] else {
                continue
            }
            ordered.append(node)
            queue.append(contentsOf: node.outgoingNodeIDs)
        }
        // A question an earlier answer already made irrelevant is passed over
        // by the executor. Showing it would invite the model to plan around
        // it, or to end the interview and drop the questions that remain.
        // Questions that depend on the trigger itself stay: "m" decides them.
        let answers = request.answeredPrefix.reduce(into: [String: ComposerInterviewAnswer]()) {
            $0[$1.nodeID] = $1
        }
        let groundings = request.priorGroundings.filter { $0.outcome == .resolvedFact }
            .reduce(into: [String: QuestionGrounding]()) { $0[$1.questionID] = $1 }
        let pending = Set(ordered.map(\.id))
        func mayBeAsked(_ node: ComposerInterviewNode, visiting: Set<String>) -> Bool {
            guard let condition = node.condition else { return true }
            if condition.nodeID == trigger.id { return true }
            if let answer = answers[condition.nodeID] {
                guard let parent = nodeMap[condition.nodeID] else { return false }
                return ComposerInterviewExecutor.satisfies(condition, answer: answer, to: parent)
            }
            if let grounding = groundings[condition.nodeID] {
                return grounding.selectedOptionID.map(condition.optionIDs.contains) == true
            }
            guard pending.contains(condition.nodeID), !visiting.contains(condition.nodeID),
                  let parent = nodeMap[condition.nodeID] else { return false }
            return mayBeAsked(parent, visiting: visiting.union([node.id]))
        }
        return ordered.filter { mayBeAsked($0, visiting: []) }
    }

    private static func encodedJSON<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    private static func patchID(for answerFingerprint: String) -> String {
        let normalized = answerFingerprint.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        let component = String(normalized)
            .split(separator: "_")
            .joined(separator: "_")
        return String("repair_\(component.isEmpty ? "answer" : component)".prefix(64))
    }

    /// The value of "m": a choice number, or text naming one.
    enum ChoiceReference: Decodable, Equatable {
        case number(Int)
        case text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }
    }

    private struct CompactResponse: Decodable {
        let outcome: String
        let replacementEntryNodeID: String?
        let nodes: [CompactNode]?
        let context: ComposerReplyContextReview.Preparation?
        /// The choice the typed words mean. A malformed value names nothing,
        /// which leaves a choice question's typed words unread and is ignored
        /// otherwise.
        let typedChoice: ChoiceReference?
        /// "n" is present but not a list of compact question nodes. It cannot
        /// be used, but it does not discard the reading in "m".
        let hasMalformedNodes: Bool

        private enum CodingKeys: String, CodingKey {
            case outcome = "o"
            case replacementEntryNodeID = "e"
            case nodes = "n"
            case context
            case typedChoice = "m"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            outcome = try values.decode(String.self, forKey: .outcome)
            replacementEntryNodeID = try values.decodeIfPresent(String.self, forKey: .replacementEntryNodeID)
            // Each part is read on its own, so that a malformed replacement
            // costs only itself, never the reading in "m".
            if let decodedNodes = try? values.decodeIfPresent([CompactNode].self, forKey: .nodes) {
                nodes = decodedNodes
                hasMalformedNodes = false
            } else {
                nodes = nil
                hasMalformedNodes = values.contains(.nodes) && (try? values.decodeNil(forKey: .nodes)) != true
            }
            context = try? values.decodeIfPresent(ComposerReplyContextReview.Preparation.self, forKey: .context)
            typedChoice = try? values.decodeIfPresent(ChoiceReference.self, forKey: .typedChoice)
        }
    }

    private struct CompactNode: Decodable {
        let id: String
        let variableID: String?
        let scope: ComposerInterviewScope?
        let authority: ComposerInterviewAuthority?
        let text: String
        let responseType: ComposerInterviewResponseType?
        let options: [CompactOption]?
        let answeredNextNodeID: String?
        let skipNextNodeID: String?
        let impactWeight: Double?

        private enum CodingKeys: String, CodingKey {
            case id = "i"
            case variableID = "v"
            case scope = "s"
            case authority = "a"
            case text = "q"
            case responseType = "r"
            case options = "o"
            case answeredNextNodeID = "x"
            case skipNextNodeID = "z"
            case impactWeight = "w"
        }

        func node() throws -> ComposerInterviewNode {
            let normalizedOptions = try (options ?? []).enumerated().map { index, option in
                try option.option(parentNodeID: id, index: index)
            }
            let normalizedResponseType = responseType ?? (
                normalizedOptions.isEmpty ? .freeText : .multipleChoice
            )
            return ComposerInterviewNode.question(
                id: id,
                variableID: variableID ?? id,
                scope: scope ?? .detail,
                authority: authority ?? .userDecision,
                text: text,
                responseType: normalizedResponseType,
                options: normalizedOptions,
                answeredNextNodeID: answeredNextNodeID,
                skipNextNodeID: skipNextNodeID
                    ?? (normalizedResponseType == .freeText ? answeredNextNodeID : nil)
                    ?? "",
                impactWeight: impactWeight
            )
        }
    }

    private struct CompactOption: Decodable {
        let kind: ComposerInterviewOptionKind?
        let label: String
        let nextNodeID: String
        let draftEffect: String?

        private enum CodingKeys: String, CodingKey {
            case kind = "k"
            case label = "l"
            case nextNodeID = "n"
            case draftEffect = "e"
        }

        func option(parentNodeID: String, index: Int) throws -> ComposerInterviewOption {
            ComposerInterviewOption(
                id: "\(parentNodeID)_o\(index + 1)",
                // A choice in the author's words is the app's to offer.
                kind: kind.map { $0 == .authorWords ? .otherUnanticipated : $0 } ?? .standard,
                label: label,
                nextNodeID: nextNodeID,
                // A model's own effect is never the author's answer.
                draftEffects: [label]
            )
        }
    }
}
