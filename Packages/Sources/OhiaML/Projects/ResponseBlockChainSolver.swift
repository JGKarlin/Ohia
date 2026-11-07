import Foundation

public enum ResponseBlockChainSolver {
    static func addEvidence(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: Set<UUID>],
        evidenceByPair: inout [ManualProjectPair: [CrossProjectLinkEvidence]]
    ) {
        let byThread = Dictionary(grouping: messages.filter { $0.threadID != nil }) { $0.threadID! }
        for (_, threadMessages) in byThread {
            let sorted = threadMessages.sorted(by: PendingReplyResolver.projectMessageSort)
            for inbound in sorted where !inbound.isSentByUser && inbound.triageVerdict?.isActionable == true {
                guard let sentReply = sorted.first(where: { $0.isSentByUser && $0.date > inbound.date }) else {
                    continue
                }
                let projectIDs = (membershipByMessageID[inbound.id] ?? [])
                    .union(membershipByMessageID[sentReply.id] ?? [])
                for pair in pairs(projectIDs) {
                    evidenceByPair[pair, default: []].append(
                        CrossProjectLinkEvidence(
                            kind: .responseBlockChain,
                            messageIDs: [inbound.id, sentReply.id],
                            explanation: "An inbound request and the later sent response span both project rows."
                        )
                    )
                }
            }
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
}
