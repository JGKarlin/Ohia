import Foundation
import OhiaCore

public enum MessageSharedEvidenceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case ccOrBcc
    case sameMessage
    case sameThread
    case replyReference
    case responseChain
    case sharedCorrespondent

    public var paintsStandaloneGlyph: Bool {
        switch self {
        case .ccOrBcc:
            return true
        case .sameMessage, .sameThread, .replyReference, .responseChain, .sharedCorrespondent:
            return false
        }
    }

    public var label: String {
        switch self {
        case .ccOrBcc: return "cc or bcc"
        case .sameMessage: return "shared message"
        case .sameThread: return "same thread"
        case .replyReference: return "reply chain"
        case .responseChain: return "response chain"
        case .sharedCorrespondent: return "shared correspondent"
        }
    }

    init(linkKind: CrossProjectLinkKind) {
        switch linkKind {
        case .sameMessage:
            self = .sameMessage
        case .sameThread:
            self = .sameThread
        case .replyReference:
            self = .replyReference
        case .responseBlockChain:
            self = .responseChain
        case .sharedCorrespondent:
            self = .sharedCorrespondent
        }
    }
}

public struct MessageStatusSignalIndex: Sendable, Equatable {
    public let revivedMessageIDs: Set<UUID>
    public let sharedEvidenceKindsByMessageID: [UUID: Set<MessageSharedEvidenceKind>]

    public init(
        revivedMessageIDs: Set<UUID> = [],
        sharedEvidenceKindsByMessageID: [UUID: Set<MessageSharedEvidenceKind>] = [:]
    ) {
        self.revivedMessageIDs = revivedMessageIDs
        self.sharedEvidenceKindsByMessageID = sharedEvidenceKindsByMessageID
    }

    public static let empty = MessageStatusSignalIndex()

    public init(projectRowsSnapshot snapshot: ProjectRowsSnapshot) {
        self.init(
            projectRowsSnapshot: snapshot,
            linkEvidence: snapshot.links.flatMap(\.evidence)
        )
    }

    init(
        projectRowsSnapshot snapshot: ProjectRowsSnapshot,
        linkEvidence: [CrossProjectLinkEvidence],
        directSharedRecipientMessageIDs: Set<UUID> = []
    ) {
        var revivedIDs = Set<UUID>()
        var sharedKinds: [UUID: Set<MessageSharedEvidenceKind>] = [:]

        for row in snapshot.visibleRows {
            for arc in row.revivalArcs {
                if let resumingMessageID = arc.resumingMessageID {
                    revivedIDs.insert(resumingMessageID)
                }
            }
            for mark in row.marks {
                if mark.isRevivedAfterInactiveGap {
                    revivedIDs.insert(mark.messageID)
                }
                if mark.sharedEvidenceKinds.isEmpty == false {
                    sharedKinds[mark.messageID, default: []].formUnion(mark.sharedEvidenceKinds)
                }
            }
        }

        for evidence in linkEvidence {
            let kind = MessageSharedEvidenceKind(linkKind: evidence.kind)
            for messageID in evidence.messageIDs {
                sharedKinds[messageID, default: []].insert(kind)
            }
        }

        for message in snapshot.messageLookup.values where message.hasDirectSharedRecipientEvidence {
            sharedKinds[message.id, default: []].insert(.ccOrBcc)
        }
        for messageID in directSharedRecipientMessageIDs {
            sharedKinds[messageID, default: []].insert(.ccOrBcc)
        }

        self.init(
            revivedMessageIDs: revivedIDs,
            sharedEvidenceKindsByMessageID: sharedKinds
        )
    }

    public func addingDirectSharedRecipientEvidence(messageIDs: Set<UUID>) -> MessageStatusSignalIndex {
        guard messageIDs.isEmpty == false else { return self }
        var sharedKinds = sharedEvidenceKindsByMessageID
        for messageID in messageIDs {
            sharedKinds[messageID, default: []].insert(.ccOrBcc)
        }
        return MessageStatusSignalIndex(
            revivedMessageIDs: revivedMessageIDs,
            sharedEvidenceKindsByMessageID: sharedKinds
        )
    }

    public func isRevivedAfterInactiveGap(_ messageID: UUID) -> Bool {
        revivedMessageIDs.contains(messageID)
    }

    public func sharedEvidenceKinds(for messageID: UUID) -> Set<MessageSharedEvidenceKind> {
        sharedEvidenceKindsByMessageID[messageID] ?? []
    }

    public func paintedSharedEvidenceKinds(
        for messageID: UUID,
        density: ProjectsDensityTier = .full,
        includeAmbient: Bool = false
    ) -> Set<MessageSharedEvidenceKind> {
        Self.paintedSharedEvidenceKinds(
            sharedEvidenceKinds(for: messageID),
            density: density,
            includeAmbient: includeAmbient
        )
    }

    public static func paintedSharedEvidenceKinds(
        _ kinds: Set<MessageSharedEvidenceKind>,
        density: ProjectsDensityTier = .full,
        includeAmbient: Bool = false
    ) -> Set<MessageSharedEvidenceKind> {
        let recipientSharedKinds = Set(kinds.filter(\.paintsStandaloneGlyph))
        if includeAmbient {
            return recipientSharedKinds
        }
        guard density.rendersEmergenceMarkers else { return [] }
        return recipientSharedKinds
    }
}

private extension ProjectMessageInput {
    var hasDirectSharedRecipientEvidence: Bool {
        participants.contains { participant in
            participant.email.isEmpty == false
                && (participant.role == .cc || participant.role == .bcc)
        }
    }
}
