import Foundation
import OhiaCore

/// Assembles the rows surfaced in the Open Loops view. Open Loops shows
/// *discourse* gaps, not tasks — unanswered questions, contested claims,
/// pending decisions, missing decision inputs, and active contradictions.
/// Per §3 of the implementation plan, the boundary test asserts the
/// output does not overlap with the Projects obligation list except via
/// intentional handoffs.
public struct OpenLoopAssembler: Sendable {
    public init() {}

    public func assemble(input: OpenLoopInput) -> [OpenLoopRow] {
        var rows: [OpenLoopRow] = []

        // Unanswered questions — derived from unresolved questions in any
        // thread plus question moves that never paired with an answer.
        for thread in input.threads {
            for dep in thread.unresolvedDependencies where dep.role == .unresolvedQuestion {
                rows.append(
                    OpenLoopRow(
                        category: .unansweredQuestion,
                        title: dep.text,
                        detail: nil,
                        evidenceLinks: [
                            EvidenceLink(
                                messageID: dep.event.messageID,
                                fieldSource: .threadContext,
                                span: nil,
                                confidence: dep.confidence,
                                timestamp: dep.event.timestamp
                            )
                        ],
                        issueKey: nil,
                        lastActive: dep.event.timestamp,
                        owner: dep.event.fromAddress,
                        sensitivityRisk: .none
                    )
                )
            }
            for dep in thread.unresolvedDependencies where dep.role == .dependency {
                rows.append(
                    OpenLoopRow(
                        category: .missingInput,
                        title: dep.text,
                        detail: "Missing input or unresolved dependency",
                        evidenceLinks: [
                            EvidenceLink(
                                messageID: dep.event.messageID,
                                fieldSource: .triageActionInputs,
                                span: nil,
                                confidence: dep.confidence,
                                timestamp: dep.event.timestamp
                            )
                        ],
                        issueKey: nil,
                        lastActive: dep.event.timestamp,
                        owner: dep.event.fromAddress,
                        sensitivityRisk: .none
                    )
                )
            }
        }

        // Contested claims — surfaced via contradiction state.
        for claim in input.claims where claim.status.contradictionState == .contested {
            rows.append(
                OpenLoopRow(
                    category: .contestedClaim,
                    title: claim.text,
                    detail: "Contradicted by a later claim",
                    evidenceLinks: claim.evidenceLinks,
                    issueKey: nil,
                    claimKey: claim.key,
                    lastActive: claim.lastAffirmed,
                    owner: claim.sourceParticipants.first,
                    sensitivityRisk: claim.status.sensitivityRisk
                )
            )
        }

        // Pending decisions — issues that have positions but no decision.
        let resolvedIssueKeys = Set(input.decisions.compactMap(\.resolvedIssueKey))
        let issuesByKey = Dictionary(uniqueKeysWithValues: input.issues.map { ($0.key, $0) })
        let issuesWithProposals = Set(
            input.arguments
                .filter { $0.type == .proposal }
                .map(\.issueKey)
        )
        for issueKey in issuesWithProposals where !resolvedIssueKeys.contains(issueKey) {
            guard let issue = issuesByKey[issueKey] else { continue }
            rows.append(
                OpenLoopRow(
                    category: .pendingDecision,
                    title: issue.title,
                    detail: "Proposal awaiting decision",
                    evidenceLinks: issue.evidenceMessageIDs.map { messageID in
                        EvidenceLink(
                            messageID: messageID,
                            fieldSource: .threadContext,
                            span: nil,
                            confidence: 0.6,
                            timestamp: issue.lastActive
                        )
                    },
                    issueKey: issue.key,
                    lastActive: issue.lastActive,
                    owner: nil,
                    sensitivityRisk: .none
                )
            )
        }

        // Active contradictions — surfaced even when neither side is
        // contested-tagged (e.g. supersession that the user has not yet
        // confirmed).
        for link in input.contradictions where !link.resolved {
            let title = "Conflict between earlier and later claim"
            rows.append(
                OpenLoopRow(
                    category: .activeContradiction,
                    title: title,
                    detail: link.type.rawValue,
                    evidenceLinks: link.sourceMessageIDs.map { messageID in
                        EvidenceLink(
                            messageID: messageID,
                            fieldSource: .crossThreadPattern,
                            span: nil,
                            confidence: 0.7,
                            timestamp: link.detectedAt
                        )
                    },
                    claimKey: link.newerClaimKey,
                    lastActive: link.detectedAt,
                    owner: nil,
                    sensitivityRisk: .none
                )
            )
        }

        return rows.sorted { lhs, rhs in
            let lhsDeadline = lhs.deadline ?? lhs.lastActive
            let rhsDeadline = rhs.deadline ?? rhs.lastActive
            if lhsDeadline != rhsDeadline { return lhsDeadline > rhsDeadline }
            return lhs.title < rhs.title
        }
    }
}

public struct OpenLoopInput: Sendable {
    public let threads: [ThreadAdjacencyResult]
    public let claims: [KnowledgeClaim]
    public let issues: [IssueNode]
    public let arguments: [ArgumentNode]
    public let decisions: [DecisionNode]
    public let contradictions: [ContradictionLink]

    public init(
        threads: [ThreadAdjacencyResult],
        claims: [KnowledgeClaim],
        issues: [IssueNode],
        arguments: [ArgumentNode],
        decisions: [DecisionNode],
        contradictions: [ContradictionLink]
    ) {
        self.threads = threads
        self.claims = claims
        self.issues = issues
        self.arguments = arguments
        self.decisions = decisions
        self.contradictions = contradictions
    }
}
