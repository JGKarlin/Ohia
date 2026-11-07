import Foundation

public enum CrossProjectLinkKind: String, Codable, Sendable, Hashable, CaseIterable {
    case sameMessage
    case sameThread
    case replyReference
    case responseBlockChain
    case sharedCorrespondent

    public var rank: Int {
        switch self {
        case .sameMessage: return 0
        case .responseBlockChain: return 1
        case .replyReference: return 2
        case .sameThread: return 3
        case .sharedCorrespondent: return 4
        }
    }

    public var shortLabel: String {
        switch self {
        case .sameMessage: return "same mail"
        case .sameThread: return "same thread"
        case .replyReference: return "reply chain"
        case .responseBlockChain: return "response chain"
        case .sharedCorrespondent: return "shared people"
        }
    }
}

public struct CrossProjectLinkEvidence: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let kind: CrossProjectLinkKind
    public let messageIDs: [UUID]
    public let explanation: String

    public init(kind: CrossProjectLinkKind, messageIDs: [UUID], explanation: String) {
        self.id = DeterministicProjectArtifactID.make(
            kind: "cross-link-evidence",
            components: [
                kind.rawValue,
                messageIDs.map { $0.uuidString.lowercased() }.joined(separator: ","),
                explanation
            ]
        )
        self.kind = kind
        self.messageIDs = messageIDs
        self.explanation = explanation
    }
}

public struct CrossProjectLink: Codable, Sendable, Identifiable, Hashable {
    public var id: String { "\(leftProjectKey)|\(rightProjectKey)" }
    public let leftProjectID: UUID
    public let rightProjectID: UUID
    public let weight: Double
    public let evidence: [CrossProjectLinkEvidence]

    public init(
        leftProjectID: UUID,
        rightProjectID: UUID,
        weight: Double,
        evidence: [CrossProjectLinkEvidence]
    ) {
        if leftProjectID.uuidString < rightProjectID.uuidString {
            self.leftProjectID = leftProjectID
            self.rightProjectID = rightProjectID
        } else {
            self.leftProjectID = rightProjectID
            self.rightProjectID = leftProjectID
        }
        self.weight = min(1, max(0, weight))
        self.evidence = evidence
    }

    public var leftProjectKey: String { leftProjectID.uuidString.lowercased() }
    public var rightProjectKey: String { rightProjectID.uuidString.lowercased() }

    public var dominantKind: CrossProjectLinkKind {
        evidence.map(\.kind).min(by: { $0.rank < $1.rank }) ?? .sameMessage
    }

    public var sortedKinds: [CrossProjectLinkKind] {
        Set(evidence.map(\.kind)).sorted(by: { $0.rank < $1.rank })
    }
}

public enum CrossProjectLinkGraph {
    static func linkEvidence(
        messages: [ProjectMessageInput],
        rows: [ProjectRow],
        membershipByMessageID: [UUID: Set<UUID>],
        includeWeakSharedCorrespondentLinks: Bool
    ) -> [ManualProjectPair: [CrossProjectLinkEvidence]] {
        var evidenceByPair: [ManualProjectPair: [CrossProjectLinkEvidence]] = [:]
        addSameMessageEvidence(
            membershipByMessageID: membershipByMessageID,
            evidenceByPair: &evidenceByPair
        )
        addSameThreadEvidence(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            evidenceByPair: &evidenceByPair
        )
        addReplyReferenceEvidence(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            evidenceByPair: &evidenceByPair
        )
        ResponseBlockChainSolver.addEvidence(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            evidenceByPair: &evidenceByPair
        )
        if includeWeakSharedCorrespondentLinks {
            addWeakCorrespondentEvidence(
                messages: messages,
                rows: rows,
                membershipByMessageID: membershipByMessageID,
                evidenceByPair: &evidenceByPair
            )
        }

        let renderedIDs = Set(rows.map(\.projectID))
        return evidenceByPair.filter { pair, _ in
            renderedIDs.contains(pair.left) && renderedIDs.contains(pair.right)
        }
    }

    public static func links(
        messages: [ProjectMessageInput],
        rows: [ProjectRow],
        membershipByMessageID: [UUID: Set<UUID>],
        includeWeakSharedCorrespondentLinks: Bool
    ) -> [CrossProjectLink] {
        links(
            from: linkEvidence(
                messages: messages,
                rows: rows,
                membershipByMessageID: membershipByMessageID,
                includeWeakSharedCorrespondentLinks: includeWeakSharedCorrespondentLinks
            )
        )
    }

    static func links(from evidenceByPair: [ManualProjectPair: [CrossProjectLinkEvidence]]) -> [CrossProjectLink] {
        evidenceByPair
            .map { pair, evidence in
                let canonicalEvidence = evidence.sorted(by: evidenceSort)
                return CrossProjectLink(
                    leftProjectID: pair.left,
                    rightProjectID: pair.right,
                    weight: weight(for: canonicalEvidence),
                    evidence: Array(canonicalEvidence.prefix(8))
                )
            }
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.id < $1.id
            }
    }

    private static func addSameMessageEvidence(
        membershipByMessageID: [UUID: Set<UUID>],
        evidenceByPair: inout [ManualProjectPair: [CrossProjectLinkEvidence]]
    ) {
        for (messageID, projectIDs) in membershipByMessageID where projectIDs.count > 1 {
            for pair in pairs(projectIDs) {
                evidenceByPair[pair, default: []].append(
                    CrossProjectLinkEvidence(
                        kind: .sameMessage,
                        messageIDs: [messageID],
                        explanation: "One message belongs to both projects."
                    )
                )
            }
        }
    }

    private static func addSameThreadEvidence(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: Set<UUID>],
        evidenceByPair: inout [ManualProjectPair: [CrossProjectLinkEvidence]]
    ) {
        let byThread = Dictionary(grouping: messages.filter { $0.threadID != nil }) { $0.threadID! }
        for threadMessages in byThread.values {
            let projectIDs = Set(threadMessages.flatMap { membershipByMessageID[$0.id] ?? [] })
            guard projectIDs.count > 1 else { continue }
            let messageIDs = threadMessages.map(\.id)
            for pair in pairs(projectIDs) {
                evidenceByPair[pair, default: []].append(
                    CrossProjectLinkEvidence(
                        kind: .sameThread,
                        messageIDs: messageIDs,
                        explanation: "A persisted thread spans both project rows."
                    )
                )
            }
        }
    }

    private static func addReplyReferenceEvidence(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: Set<UUID>],
        evidenceByPair: inout [ManualProjectPair: [CrossProjectLinkEvidence]]
    ) {
        let byHeader = messages.reduce(into: [String: ProjectMessageInput]()) { result, message in
            guard let header = message.messageIDHeader else { return }
            result[header] = message
        }
        for message in messages {
            let messageProjects = membershipByMessageID[message.id] ?? []
            guard messageProjects.isEmpty == false else { continue }
            for reference in message.referencesHeaders {
                guard let referenced = byHeader[reference] else { continue }
                let referencedProjects = membershipByMessageID[referenced.id] ?? []
                for pair in pairs(messageProjects.union(referencedProjects)) {
                    evidenceByPair[pair, default: []].append(
                        CrossProjectLinkEvidence(
                            kind: .replyReference,
                            messageIDs: [message.id, referenced.id],
                            explanation: "Reply/reference headers connect messages across both project rows."
                        )
                    )
                }
            }
        }
    }

    private static func addWeakCorrespondentEvidence(
        messages: [ProjectMessageInput],
        rows: [ProjectRow],
        membershipByMessageID: [UUID: Set<UUID>],
        evidenceByPair: inout [ManualProjectPair: [CrossProjectLinkEvidence]]
    ) {
        let renderedIDs = Set(rows.map(\.projectID))
        var correspondentsByProject: [UUID: Set<String>] = [:]
        var examples: [ProjectCorrespondentKey: UUID] = [:]
        for message in messages {
            for projectID in membershipByMessageID[message.id] ?? [] where renderedIDs.contains(projectID) {
                correspondentsByProject[projectID, default: []].formUnion(message.normalizedParticipantEmails)
                for email in message.normalizedParticipantEmails {
                    examples[ProjectCorrespondentKey(projectID: projectID, email: email)] = message.id
                }
            }
        }
        for pair in pairs(Set(correspondentsByProject.keys)) {
            let shared = (correspondentsByProject[pair.left] ?? [])
                .intersection(correspondentsByProject[pair.right] ?? [])
            guard let email = shared.sorted().first else { continue }
            let messageIDs = [
                examples[ProjectCorrespondentKey(projectID: pair.left, email: email)],
                examples[ProjectCorrespondentKey(projectID: pair.right, email: email)]
            ].compactMap { $0 }
            evidenceByPair[pair, default: []].append(
                CrossProjectLinkEvidence(
                    kind: .sharedCorrespondent,
                    messageIDs: messageIDs,
                    explanation: "Both rows include \(email)."
                )
            )
        }
    }

    private static func pairs(_ projectIDs: Set<UUID>) -> [ManualProjectPair] {
        let sorted = projectIDs.sorted { $0.uuidString < $1.uuidString }
        guard sorted.count > 1 else { return [] }
        var result: [ManualProjectPair] = []
        for leftIndex in sorted.indices {
            for rightIndex in sorted.indices where rightIndex > leftIndex {
                result.append(ManualProjectPair(sorted[leftIndex], sorted[rightIndex]))
            }
        }
        return result
    }

    private static func weight(for evidence: [CrossProjectLinkEvidence]) -> Double {
        min(1, evidence.reduce(0) { partial, item in
            let value: Double = switch item.kind {
            case .sameMessage: 0.40
            case .sameThread: 0.30
            case .replyReference: 0.35
            case .responseBlockChain: 0.45
            case .sharedCorrespondent: 0.12
            }
            return partial + value
        })
    }

    private static func evidenceSort(
        _ lhs: CrossProjectLinkEvidence,
        _ rhs: CrossProjectLinkEvidence
    ) -> Bool {
        if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
        let leftIDs = lhs.messageIDs.map { $0.uuidString.lowercased() }
        let rightIDs = rhs.messageIDs.map { $0.uuidString.lowercased() }
        if leftIDs != rightIDs {
            return leftIDs.lexicographicallyPrecedes(rightIDs)
        }
        if lhs.explanation != rhs.explanation { return lhs.explanation < rhs.explanation }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct ManualProjectPair: Hashable, Sendable {
    let left: UUID
    let right: UUID

    init(_ lhs: UUID, _ rhs: UUID) {
        if lhs.uuidString < rhs.uuidString {
            left = lhs
            right = rhs
        } else {
            left = rhs
            right = lhs
        }
    }
}

private struct ProjectCorrespondentKey: Hashable {
    let projectID: UUID
    let email: String
}
