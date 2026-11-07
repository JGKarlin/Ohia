import Foundation
import OhiaCore

/// Build the IBIS graph (issues, positions, supports, objections,
/// constraints, decisions) from a thread-adjacency result + per-message
/// memory. The graph is consumed by the SwiftUI Issue Map view.
public struct IBISGraphBuilder: Sendable {
    public init() {}

    public func build(input: IBISGraphInput) -> DiscourseGraph {
        do {
            return try build(input: input, shouldCancel: { false })
        } catch {
            preconditionFailure("Unexpected cancellation in non-cancellable IBIS graph build")
        }
    }

    public func build(
        input: IBISGraphInput,
        shouldCancel: @Sendable () -> Bool
    ) throws -> DiscourseGraph {
        var issues: [String: IssueAccumulator] = [:]
        var arguments: [ArgumentNode] = []
        var decisions: [DecisionNode] = []
        var context = GraphBuildContext(scopeHints: input.activeScope)

        for thread in input.threads {
            try checkCancellation(shouldCancel)
            try ingest(
                thread: thread,
                issues: &issues,
                arguments: &arguments,
                decisions: &decisions,
                context: &context,
                shouldCancel: shouldCancel
            )
        }

        return DiscourseGraph(
            issues: issues.values.map(\.node).sorted { $0.firstSeen < $1.firstSeen },
            arguments: arguments,
            decisions: decisions
        )
    }

    private func ingest(
        thread: ThreadAdjacencyResult,
        issues: inout [String: IssueAccumulator],
        arguments: inout [ArgumentNode],
        decisions: inout [DecisionNode],
        context: inout GraphBuildContext,
        shouldCancel: @Sendable () -> Bool
    ) throws {
        // Issue from each unresolved dependency / question.
        for (index, dep) in thread.unresolvedDependencies.enumerated() {
            if index.isMultiple(of: 32) { try checkCancellation(shouldCancel) }
            let issueKey = context.key(
                text: dep.text,
                kind: .issue,
                scope: .active
            )
            let status: IssueStatus
            switch dep.role {
            case .unresolvedQuestion, .dependency: status = .open
            case .position:                         status = .unresolved
            default:                                status = .open
            }

            upsertIssue(
                key: issueKey,
                title: dep.text,
                timestamp: dep.event.timestamp,
                threadID: thread.threadID,
                messageID: dep.event.messageID,
                context: context,
                status: status,
                statusPolicy: .preserveUnlessNonOpen,
                issues: &issues
            )
        }

        // Arguments + decisions from adjacency pairs.
        for (index, pair) in thread.pairs.enumerated() {
            if index.isMultiple(of: 32) { try checkCancellation(shouldCancel) }
            switch pair.kind {
            case .proposalObjection:
                let issueKey = registerIssue(
                    title: pair.opener.move.target ?? "Open proposal",
                    timestamp: pair.opener.event.timestamp,
                    threadID: thread.threadID,
                    messageID: pair.opener.event.messageID,
                    context: &context,
                    status: .contested,
                    issues: &issues
                )
                let openerArgument = makeArgument(
                    for: pair.opener,
                    issueKey: issueKey,
                    type: .proposal,
                    stance: .affirming,
                    context: &context
                )
                let closerArgument = makeArgument(
                    for: pair.closer,
                    issueKey: issueKey,
                    type: .objection,
                    stance: .opposing,
                    context: &context
                )
                arguments.append(openerArgument)
                arguments.append(closerArgument)
            case .approvalDecision:
                let issueKey = registerIssue(
                    title: pair.opener.move.target ?? "Open proposal",
                    timestamp: pair.opener.event.timestamp,
                    threadID: thread.threadID,
                    messageID: pair.opener.event.messageID,
                    context: &context,
                    status: .resolved,
                    issues: &issues
                )
                let openerArgument = makeArgument(
                    for: pair.opener,
                    issueKey: issueKey,
                    type: .proposal,
                    stance: .affirming,
                    context: &context
                )
                arguments.append(openerArgument)
                let decisionKey = context.key(
                    text: pair.closer.move.target ?? pair.opener.move.target ?? "Approval",
                    kind: .decision,
                    scope: .active
                )
                decisions.append(
                    DecisionNode(
                        key: decisionKey,
                        text: pair.closer.move.target ?? "Approval",
                        decider: pair.closer.event.fromAddress,
                        decidedAt: pair.closer.event.timestamp,
                        resolvedIssueKey: issueKey,
                        signOffMessageIDs: [pair.closer.event.messageID],
                        evidenceLinks: [
                            EvidenceLink(
                                messageID: pair.closer.event.messageID,
                                fieldSource: .threadContext,
                                span: pair.closer.move.evidenceSpan,
                                confidence: pair.closer.move.confidence,
                                timestamp: pair.closer.event.timestamp
                            )
                        ]
                    )
                )
            case .questionAnswer:
                let issueKey = registerIssue(
                    title: pair.opener.move.target ?? "Question",
                    timestamp: pair.opener.event.timestamp,
                    threadID: thread.threadID,
                    messageID: pair.opener.event.messageID,
                    context: &context,
                    status: .resolved,
                    issues: &issues
                )
                let clarification = makeArgument(
                    for: pair.closer,
                    issueKey: issueKey,
                    type: .clarification,
                    stance: .neutral,
                    context: &context
                )
                arguments.append(clarification)
            case .requestCommitment:
                let issueKey = registerIssue(
                    title: pair.opener.move.target ?? "Request",
                    timestamp: pair.opener.event.timestamp,
                    threadID: thread.threadID,
                    messageID: pair.opener.event.messageID,
                    context: &context,
                    status: .resolved,
                    issues: &issues
                )
                let support = makeArgument(
                    for: pair.closer,
                    issueKey: issueKey,
                    type: .support,
                    stance: .affirming,
                    context: &context
                )
                arguments.append(support)
            }
        }

        for (index, anchor) in thread.decisions.enumerated() {
            if index.isMultiple(of: 32) { try checkCancellation(shouldCancel) }
            let decisionText = anchor.approvalMove.target
                ?? anchor.resolvedProposal?.target
                ?? "Decision recorded"
            let decisionKey = context.key(
                text: decisionText,
                kind: .decision,
                scope: .active
            )
            decisions.append(
                DecisionNode(
                    key: decisionKey,
                    text: decisionText,
                    decider: anchor.event.fromAddress,
                    decidedAt: anchor.event.timestamp,
                    resolvedIssueKey: nil,
                    signOffMessageIDs: [anchor.event.messageID],
                    evidenceLinks: [
                        EvidenceLink(
                            messageID: anchor.event.messageID,
                            fieldSource: .threadContext,
                            span: anchor.approvalMove.evidenceSpan,
                            confidence: anchor.approvalMove.confidence,
                            timestamp: anchor.event.timestamp
                        )
                    ]
                )
            )
        }
    }

    private func registerIssue(
        title: String,
        timestamp: Date,
        threadID: UUID?,
        messageID: UUID,
        context: inout GraphBuildContext,
        status: IssueStatus,
        issues: inout [String: IssueAccumulator]
    ) -> String {
        let key = context.key(
            text: title,
            kind: .issue,
            scope: .active
        )
        upsertIssue(
            key: key,
            title: title,
            timestamp: timestamp,
            threadID: threadID,
            messageID: messageID,
            context: context,
            status: status,
            statusPolicy: .override,
            issues: &issues
        )
        return key
    }

    private func upsertIssue(
        key: String,
        title: String,
        timestamp: Date,
        threadID: UUID?,
        messageID: UUID,
        context: GraphBuildContext,
        status: IssueStatus,
        statusPolicy: IssueStatusPolicy,
        issues: inout [String: IssueAccumulator]
    ) {
        if var accumulator = issues[key] {
            accumulator.add(
                timestamp: timestamp,
                threadID: threadID,
                messageID: messageID,
                status: status,
                statusPolicy: statusPolicy
            )
            issues[key] = accumulator
        } else {
            issues[key] = IssueAccumulator(
                key: key,
                title: title,
                status: status,
                projectLabels: context.projectLabels,
                teamLabels: context.teamLabels,
                timestamp: timestamp,
                threadID: threadID,
                messageID: messageID
            )
        }
    }

    private func makeArgument(
        for pending: PendingMove,
        issueKey: String,
        type: ArgumentType,
        stance: ArgumentStance,
        context: inout GraphBuildContext
    ) -> ArgumentNode {
        let key = context.key(
            text: pending.move.target ?? type.rawValue,
            kind: .claim,
            scope: .empty
        )
        return ArgumentNode(
            key: key,
            issueKey: issueKey,
            type: type,
            stance: stance,
            text: pending.move.target ?? type.rawValue,
            evidenceLinks: [
                EvidenceLink(
                    messageID: pending.event.messageID,
                    fieldSource: .threadContext,
                    span: pending.move.evidenceSpan,
                    confidence: pending.move.confidence,
                    timestamp: pending.event.timestamp
                )
            ],
            firstSeen: pending.event.timestamp
        )
    }

    private func checkCancellation(_ shouldCancel: @Sendable () -> Bool) throws {
        if shouldCancel() {
            throw CancellationError()
        }
    }

    private enum IssueStatusPolicy {
        case override
        case preserveUnlessNonOpen
    }

    private enum GraphKeyScope {
        case active
        case empty
    }

    private struct GraphKeyCacheKey: Hashable {
        let text: String
        let kind: String
        let scopeFingerprint: String
    }

    private struct GraphBuildContext {
        let scopeFingerprint: String
        let emptyScopeFingerprint: String
        let projectLabels: [String]
        let teamLabels: [String]
        private var keyCache: [GraphKeyCacheKey: String] = [:]

        init(scopeHints: [ScopeHint]) {
            self.scopeFingerprint = ConversationCurationKey.makeScopeFingerprint(scopeHints)
            self.emptyScopeFingerprint = ConversationCurationKey.makeScopeFingerprint([])
            self.projectLabels = scopeHints.filter { $0.kind == .project }.map(\.value)
            self.teamLabels = scopeHints.filter { $0.kind == .team }.map(\.value)
        }

        mutating func key(
            text: String,
            kind: ConversationCurationAction.TargetKind,
            scope: GraphKeyScope
        ) -> String {
            let scopeFingerprint = switch scope {
            case .active: self.scopeFingerprint
            case .empty: self.emptyScopeFingerprint
            }
            let cacheKey = GraphKeyCacheKey(
                text: text,
                kind: kind.rawValue,
                scopeFingerprint: scopeFingerprint
            )
            if let cached = keyCache[cacheKey] {
                return cached
            }
            let key = ConversationCurationKey.make(
                text: text,
                kind: kind,
                scopeFingerprint: scopeFingerprint,
                extractionVersion: DiscourseMemory.qwenVersion,
                supportingMessageContentHashes: []
            ).targetKey
            keyCache[cacheKey] = key
            return key
        }
    }

    private struct IssueAccumulator {
        let key: String
        let title: String
        var status: IssueStatus
        let projectLabels: [String]
        let teamLabels: [String]
        var firstSeen: Date
        var lastActive: Date
        private var relatedThreadIDs: [UUID] = []
        private var relatedThreadIDSet: Set<UUID> = []
        private var evidenceMessageIDs: [UUID] = []
        private var evidenceMessageIDSet: Set<UUID> = []

        init(
            key: String,
            title: String,
            status: IssueStatus,
            projectLabels: [String],
            teamLabels: [String],
            timestamp: Date,
            threadID: UUID?,
            messageID: UUID
        ) {
            self.key = key
            self.title = title
            self.status = status
            self.projectLabels = projectLabels
            self.teamLabels = teamLabels
            self.firstSeen = timestamp
            self.lastActive = timestamp
            appendThreadID(threadID)
            appendEvidenceMessageID(messageID)
        }

        mutating func add(
            timestamp: Date,
            threadID: UUID?,
            messageID: UUID,
            status: IssueStatus,
            statusPolicy: IssueStatusPolicy
        ) {
            switch statusPolicy {
            case .override:
                self.status = status
            case .preserveUnlessNonOpen:
                if status != .open {
                    self.status = status
                }
            }
            firstSeen = min(firstSeen, timestamp)
            lastActive = max(lastActive, timestamp)
            appendThreadID(threadID)
            appendEvidenceMessageID(messageID)
        }

        var node: IssueNode {
            IssueNode(
                key: key,
                title: title,
                status: status,
                projectLabels: projectLabels,
                teamLabels: teamLabels,
                firstSeen: firstSeen,
                lastActive: lastActive,
                relatedThreadIDs: relatedThreadIDs,
                evidenceMessageIDs: evidenceMessageIDs
            )
        }

        private mutating func appendThreadID(_ threadID: UUID?) {
            guard let threadID else { return }
            if relatedThreadIDSet.insert(threadID).inserted {
                relatedThreadIDs.append(threadID)
            }
        }

        private mutating func appendEvidenceMessageID(_ messageID: UUID) {
            if evidenceMessageIDSet.insert(messageID).inserted {
                evidenceMessageIDs.append(messageID)
            }
        }
    }
}

public struct IBISGraphInput: Sendable {
    public let threads: [ThreadAdjacencyResult]
    public let activeScope: [ScopeHint]
    public init(threads: [ThreadAdjacencyResult], activeScope: [ScopeHint]) {
        self.threads = threads
        self.activeScope = activeScope
    }
}

public struct DiscourseGraph: Sendable {
    public let issues: [IssueNode]
    public let arguments: [ArgumentNode]
    public let decisions: [DecisionNode]
    public init(issues: [IssueNode], arguments: [ArgumentNode], decisions: [DecisionNode]) {
        self.issues = issues
        self.arguments = arguments
        self.decisions = decisions
    }
}
