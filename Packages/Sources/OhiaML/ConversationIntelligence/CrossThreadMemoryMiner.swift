import Foundation
import OhiaCore

/// Bounded cross-thread mining. Operates over the snapshot's message set
/// and emits precedent, tacit-rule, and supersession candidates by
/// detecting the §11 patterns plus reaffirmed-precedent through embedding
/// similarity. Every loop checks the budget so a large mailbox can't
/// monopolize the main actor — on cap the snapshot exits with
/// `coverage == .partial` and surfaces a "broaden search" affordance.
public struct CrossThreadMemoryMiner: Sendable {
    public struct Budget: Sendable {
        public let maxThreadsCompared: Int
        public let maxCandidatesPerPattern: Int
        public let wallClockSeconds: Double

        public init(
            maxThreadsCompared: Int = 200,
            maxCandidatesPerPattern: Int = 50,
            wallClockSeconds: Double = 4.0
        ) {
            self.maxThreadsCompared = maxThreadsCompared
            self.maxCandidatesPerPattern = maxCandidatesPerPattern
            self.wallClockSeconds = wallClockSeconds
        }
        public static let `default` = Budget()
    }

    public let budget: Budget

    public init(budget: Budget = .default) {
        self.budget = budget
    }

    public func mine(input: CrossThreadInput) -> CrossThreadResult {
        let deadline = Date().addingTimeInterval(budget.wallClockSeconds)
        var hitBudget = false

        var precedents: [Precedent] = []
        var tacit: [TacitRule] = []
        var supersessions: [SupersessionRecord] = []

        precedents.append(
            contentsOf: minePrecedents(
                events: input.events,
                messageMemory: input.messageMemory,
                deadline: deadline,
                hitBudget: &hitBudget
            )
        )

        if !hitBudget {
            tacit.append(
                contentsOf: mineTacitRules(
                    events: input.events,
                    messageMemory: input.messageMemory,
                    languageByMessage: input.languageByMessage,
                    deadline: deadline,
                    hitBudget: &hitBudget
                )
            )
        }

        if !hitBudget {
            supersessions.append(
                contentsOf: mineSupersessions(
                    events: input.events,
                    messageMemory: input.messageMemory,
                    deadline: deadline,
                    hitBudget: &hitBudget
                )
            )
        }

        return CrossThreadResult(
            precedents: precedents,
            tacitRules: tacit,
            supersessions: supersessions,
            hitBudget: hitBudget
        )
    }

    // MARK: - Precedents

    private func minePrecedents(
        events: [ConversationEvent],
        messageMemory: [UUID: DiscourseMemory],
        deadline: Date,
        hitBudget: inout Bool
    ) -> [Precedent] {
        var threadResolutions: [String: [ResolutionInstance]] = [:]
        var threadsSeen = 0

        for event in events {
            if Date() > deadline { hitBudget = true; break }
            threadsSeen += 1
            if threadsSeen > budget.maxThreadsCompared { hitBudget = true; break }

            guard let memory = messageMemory[event.messageID] else { continue }
            for decision in memory.decisionCandidates {
                let normalizedKey = ConversationCurationKey.normalize(text: decision.text)
                threadResolutions[normalizedKey, default: []].append(
                    ResolutionInstance(
                        threadID: event.threadID,
                        messageID: event.messageID,
                        timestamp: event.timestamp,
                        confidence: decision.confidence
                    )
                )
            }
            for precedent in memory.precedentSignals {
                let normalizedKey = ConversationCurationKey.normalize(text: precedent.statement)
                threadResolutions[normalizedKey, default: []].append(
                    ResolutionInstance(
                        threadID: event.threadID,
                        messageID: event.messageID,
                        timestamp: event.timestamp,
                        confidence: precedent.confidence
                    )
                )
            }
        }

        var output: [Precedent] = []
        for (normalized, instances) in threadResolutions {
            if output.count >= budget.maxCandidatesPerPattern { hitBudget = true; break }
            let distinctThreads = Set(instances.compactMap { $0.threadID })
            guard distinctThreads.count >= 2 else { continue }
            let evidenceLinks = instances.map { instance in
                EvidenceLink(
                    messageID: instance.messageID,
                    fieldSource: .crossThreadPattern,
                    span: nil,
                    confidence: instance.confidence,
                    timestamp: instance.timestamp
                )
            }
            let applicability = min(1.0, 0.4 + Double(distinctThreads.count) * 0.15)
            let key = ConversationCurationKey.make(
                text: normalized,
                kind: .precedent,
                scope: [],
                extractionVersion: DiscourseMemory.qwenVersion,
                supportingMessageContentHashes: []
            ).targetKey
            output.append(
                Precedent(
                    key: key,
                    statement: normalized,
                    recurrenceCount: instances.count,
                    sourceThreadIDs: Array(distinctThreads),
                    applicabilityScore: applicability,
                    exceptions: [],
                    evidenceLinks: evidenceLinks,
                    sensitivityRisk: .none
                )
            )
        }
        return output
    }

    // MARK: - Tacit rules

    private func mineTacitRules(
        events: [ConversationEvent],
        messageMemory: [UUID: DiscourseMemory],
        languageByMessage: [UUID: String?],
        deadline: Date,
        hitBudget: inout Bool
    ) -> [TacitRule] {
        var output: [TacitRule] = []

        // Pattern A: repeated assignee — same target appearing for the
        // same task type across multiple threads.
        var assigneeBuckets: [String: [TacitInstance]] = [:]
        // Pattern B: explicit norm language directly emitted by the
        // seeder or the LLM.
        var normLanguage: [String: [TacitInstance]] = [:]

        for event in events {
            if Date() > deadline { hitBudget = true; break }
            guard let memory = messageMemory[event.messageID] else { continue }
            for signal in memory.tacitRuleSignals {
                let key = ConversationCurationKey.normalize(text: signal.rule)
                let instance = TacitInstance(
                    threadID: event.threadID,
                    messageID: event.messageID,
                    timestamp: event.timestamp,
                    confidence: signal.confidence
                )
                if signal.pattern == .explicitNormLanguage {
                    normLanguage[key, default: []].append(instance)
                } else if signal.pattern == .repeatedAssignee || signal.pattern == .repeatedApprovalPath {
                    assigneeBuckets[key, default: []].append(instance)
                }
            }
            // Detect repeated assignee from triage signals — if a move's
            // target appears across multiple threads, that's evidence.
            for move in memory.discourseMoves where move.kind == .commitment {
                guard let target = move.target else { continue }
                let key = "commit:\(target)"
                assigneeBuckets[key, default: []].append(
                    TacitInstance(
                        threadID: event.threadID,
                        messageID: event.messageID,
                        timestamp: event.timestamp,
                        confidence: move.confidence
                    )
                )
            }
            // Also catch norm-language fragments that may have appeared
            // in the body via the lexicon, when the seeder didn't.
            if let summary = event.summary,
               let language = languageByMessage[event.messageID, default: nil],
               NormLanguageLexicon.containsNormLanguage(summary, language: language) {
                let key = ConversationCurationKey.normalize(text: summary)
                normLanguage[key, default: []].append(
                    TacitInstance(
                        threadID: event.threadID,
                        messageID: event.messageID,
                        timestamp: event.timestamp,
                        confidence: 0.5
                    )
                )
            }
        }

        for (key, instances) in normLanguage {
            if output.count >= budget.maxCandidatesPerPattern { hitBudget = true; break }
            guard !instances.isEmpty else { continue }
            output.append(
                makeTacitRule(
                    text: key,
                    pattern: .explicitNormLanguage,
                    instances: instances
                )
            )
        }
        for (key, instances) in assigneeBuckets {
            if output.count >= budget.maxCandidatesPerPattern { hitBudget = true; break }
            let distinctThreads = Set(instances.compactMap { $0.threadID })
            guard distinctThreads.count >= 2 else { continue }
            let text = key.hasPrefix("commit:")
                ? "Commitment routed via \(String(key.dropFirst("commit:".count)))"
                : key
            output.append(
                makeTacitRule(
                    text: text,
                    pattern: .repeatedAssignee,
                    instances: instances
                )
            )
        }
        return output
    }

    private func makeTacitRule(
        text: String,
        pattern: TacitRulePattern,
        instances: [TacitInstance]
    ) -> TacitRule {
        let confidence = min(
            1.0,
            instances.map(\.confidence).reduce(0, +) / Double(max(1, instances.count))
        )
        let key = ConversationCurationKey.make(
            text: text,
            kind: .tacitRule,
            scope: [],
            extractionVersion: DiscourseMemory.qwenVersion,
            supportingMessageContentHashes: []
        ).targetKey
        let evidenceLinks = instances.map { instance in
            EvidenceLink(
                messageID: instance.messageID,
                fieldSource: .crossThreadPattern,
                span: nil,
                confidence: instance.confidence,
                timestamp: instance.timestamp
            )
        }
        return TacitRule(
            key: key,
            rule: text,
            pattern: pattern,
            confidence: confidence,
            scope: [],
            confirmationState: .none,
            evidenceLinks: evidenceLinks,
            sensitivityRisk: .none
        )
    }

    // MARK: - Supersessions

    private func mineSupersessions(
        events: [ConversationEvent],
        messageMemory: [UUID: DiscourseMemory],
        deadline: Date,
        hitBudget: inout Bool
    ) -> [SupersessionRecord] {
        var output: [SupersessionRecord] = []
        for event in events {
            if Date() > deadline { hitBudget = true; break }
            guard let memory = messageMemory[event.messageID] else { continue }
            for signal in memory.supersessionSignals {
                if output.count >= budget.maxCandidatesPerPattern { hitBudget = true; break }
                let newerKey = ConversationCurationKey.make(
                    text: signal.newerStatement,
                    kind: .claim,
                    scope: [],
                    extractionVersion: DiscourseMemory.qwenVersion,
                    supportingMessageContentHashes: []
                ).targetKey
                let olderKey = ConversationCurationKey.make(
                    text: signal.olderHint ?? signal.newerStatement,
                    kind: .claim,
                    scope: [],
                    extractionVersion: DiscourseMemory.qwenVersion,
                    supportingMessageContentHashes: []
                ).targetKey
                output.append(
                    SupersessionRecord(
                        olderClaimKey: olderKey,
                        newerClaimKey: newerKey,
                        detectedAt: event.timestamp,
                        sourceMessageIDs: [event.messageID]
                    )
                )
            }
        }
        return output
    }
}

public struct CrossThreadInput: Sendable {
    public let events: [ConversationEvent]
    public let messageMemory: [UUID: DiscourseMemory]
    public let languageByMessage: [UUID: String?]
    public init(
        events: [ConversationEvent],
        messageMemory: [UUID: DiscourseMemory],
        languageByMessage: [UUID: String?]
    ) {
        self.events = events
        self.messageMemory = messageMemory
        self.languageByMessage = languageByMessage
    }
}

public struct CrossThreadResult: Sendable {
    public let precedents: [Precedent]
    public let tacitRules: [TacitRule]
    public let supersessions: [SupersessionRecord]
    public let hitBudget: Bool
}

private struct ResolutionInstance: Sendable {
    let threadID: UUID?
    let messageID: UUID
    let timestamp: Date
    let confidence: Double
}

private struct TacitInstance: Sendable {
    let threadID: UUID?
    let messageID: UUID
    let timestamp: Date
    let confidence: Double
}
