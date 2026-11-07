import Foundation
import OhiaCore

/// Reconstructs adjacency inside a single thread: question↔answer pairs,
/// request↔commitment pairs, proposal↔objection pairs, approval↔decision
/// pairs, and unresolved dependencies. Operates on
/// `(ConversationEvent, DiscourseMemory)` pairs in chronological order so
/// it never touches SwiftData directly — the data controller pre-resolves
/// the inputs and hands them in.
public struct ThreadAdjacencyAnalyzer: Sendable {
    public init() {}

    public func analyze(_ thread: ThreadInput) -> ThreadAdjacencyResult {
        let ordered = thread.messages.sorted { $0.event.timestamp < $1.event.timestamp }
        var pairs: [DiscoursePair] = []
        var openQuestions: [PendingMove] = []
        var openProposals: [PendingMove] = []
        var openRequests: [PendingMove] = []
        var unresolvedDependencies: [UnresolvedDependency] = []
        var decisions: [DecisionAnchor] = []

        for (index, item) in ordered.enumerated() {
            let event = item.event
            for move in item.memory.discourseMoves {
                switch move.kind {
                case .question:
                    openQuestions.append(
                        PendingMove(event: event, move: move, indexInThread: index)
                    )
                case .request:
                    openRequests.append(
                        PendingMove(event: event, move: move, indexInThread: index)
                    )
                case .proposal:
                    openProposals.append(
                        PendingMove(event: event, move: move, indexInThread: index)
                    )
                case .answer:
                    if let opener = openQuestions.popLast() {
                        pairs.append(
                            DiscoursePair(
                                kind: .questionAnswer,
                                opener: opener,
                                closer: PendingMove(event: event, move: move, indexInThread: index)
                            )
                        )
                    }
                case .commitment:
                    if let opener = openRequests.popLast() {
                        pairs.append(
                            DiscoursePair(
                                kind: .requestCommitment,
                                opener: opener,
                                closer: PendingMove(event: event, move: move, indexInThread: index)
                            )
                        )
                    }
                case .refusal, .objection, .escalation:
                    if let opener = openProposals.popLast() {
                        pairs.append(
                            DiscoursePair(
                                kind: .proposalObjection,
                                opener: opener,
                                closer: PendingMove(event: event, move: move, indexInThread: index)
                            )
                        )
                    }
                case .approval:
                    if let opener = openProposals.popLast() {
                        let closer = PendingMove(event: event, move: move, indexInThread: index)
                        pairs.append(
                            DiscoursePair(
                                kind: .approvalDecision,
                                opener: opener,
                                closer: closer
                            )
                        )
                        decisions.append(
                            DecisionAnchor(
                                event: event,
                                approvalMove: move,
                                resolvedProposal: opener.move
                            )
                        )
                    }
                case .closure:
                    decisions.append(
                        DecisionAnchor(
                            event: event,
                            approvalMove: move,
                            resolvedProposal: nil
                        )
                    )
                default:
                    continue
                }
            }

            for role in item.memory.ibisRoles where role.role == .dependency || role.role == .unresolvedQuestion {
                unresolvedDependencies.append(
                    UnresolvedDependency(
                        event: event,
                        text: role.text,
                        role: role.role,
                        confidence: role.confidence
                    )
                )
            }
        }

        let stillOpenQuestions = openQuestions.map { UnresolvedDependency(event: $0.event, text: $0.move.target ?? "unspecified question", role: .unresolvedQuestion, confidence: $0.move.confidence) }
        let stillOpenProposals = openProposals.map { UnresolvedDependency(event: $0.event, text: $0.move.target ?? "open proposal", role: .position, confidence: $0.move.confidence) }
        let stillOpenRequests = openRequests.map { UnresolvedDependency(event: $0.event, text: $0.move.target ?? "open request", role: .dependency, confidence: $0.move.confidence) }
        unresolvedDependencies.append(contentsOf: stillOpenQuestions)
        unresolvedDependencies.append(contentsOf: stillOpenProposals)
        unresolvedDependencies.append(contentsOf: stillOpenRequests)

        return ThreadAdjacencyResult(
            threadID: thread.threadID,
            pairs: pairs,
            unresolvedDependencies: unresolvedDependencies,
            decisions: decisions
        )
    }
}

public struct ThreadInput: Sendable {
    public let threadID: UUID?
    public let messages: [ThreadMessageInput]
    public init(threadID: UUID?, messages: [ThreadMessageInput]) {
        self.threadID = threadID
        self.messages = messages
    }
}

public struct ThreadMessageInput: Sendable {
    public let event: ConversationEvent
    public let memory: DiscourseMemory
    public init(event: ConversationEvent, memory: DiscourseMemory) {
        self.event = event
        self.memory = memory
    }
}

public struct ThreadAdjacencyResult: Sendable {
    public let threadID: UUID?
    public let pairs: [DiscoursePair]
    public let unresolvedDependencies: [UnresolvedDependency]
    public let decisions: [DecisionAnchor]
}

public struct DiscoursePair: Sendable {
    public enum Kind: Sendable {
        case questionAnswer
        case requestCommitment
        case proposalObjection
        case approvalDecision
    }
    public let kind: Kind
    public let opener: PendingMove
    public let closer: PendingMove
}

public struct PendingMove: Sendable {
    public let event: ConversationEvent
    public let move: DiscourseMove
    public let indexInThread: Int
}

public struct UnresolvedDependency: Sendable {
    public let event: ConversationEvent
    public let text: String
    public let role: IBISRole
    public let confidence: Double
}

public struct DecisionAnchor: Sendable {
    public let event: ConversationEvent
    public let approvalMove: DiscourseMove
    public let resolvedProposal: DiscourseMove?
}
