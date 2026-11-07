import Foundation

/// Applies the Project lens's deterministic row-lifecycle gate to the shared
/// per-message attention state. Message-level actions stay shared across
/// lenses; project-level resolved/pinned/hidden state should be kept out of the
/// `ProjectRowsSnapshot` passed here unless the caller intentionally wants a
/// Projects-only view.
public enum MessageAttentionProjectLifecycleGate {
    public static func apply(
        states: [UUID: MessageAttentionState],
        projectRowsSnapshot: ProjectRowsSnapshot
    ) -> [UUID: MessageAttentionState] {
        apply(
            states: states,
            projectRowsSnapshot: projectRowsSnapshot,
            projectMemberMessageIDs: projectMemberMessageIDs(in: projectRowsSnapshot)
        )
    }

    public static func apply(
        states: [UUID: MessageAttentionState],
        projectRowsSnapshot: ProjectRowsSnapshot,
        projectMemberMessageIDs: Set<UUID>
    ) -> [UUID: MessageAttentionState] {
        guard states.isEmpty == false,
              projectMemberMessageIDs.isEmpty == false else {
            return states
        }

        let visibleKindsByMessageID = visibleObligationKindsByMessageID(in: projectRowsSnapshot)
        var gated = states
        for messageID in projectMemberMessageIDs {
            guard let state = gated[messageID] else { continue }
            let visibleKinds = visibleKindsByMessageID[messageID] ?? []
            let openKinds = state.openKinds.intersection(visibleKinds)
            guard openKinds != state.openKinds else { continue }
            gated[messageID] = MessageAttentionState(
                messageID: state.messageID,
                openKinds: openKinds,
                clearsByMessageID: state.clearsByMessageID
            )
        }
        return gated
    }

    private static func projectMemberMessageIDs(in snapshot: ProjectRowsSnapshot) -> Set<UUID> {
        Set(snapshot.membershipByMessageID.compactMap { messageID, memberships in
            memberships.isEmpty ? nil : messageID
        })
    }

    private static func visibleObligationKindsByMessageID(
        in snapshot: ProjectRowsSnapshot
    ) -> [UUID: Set<MessageAttentionKind>] {
        snapshot.visibleRows
            .flatMap(\.obligations)
            .reduce(into: [UUID: Set<MessageAttentionKind>]()) { result, obligation in
                switch obligation.kind {
                case .pendingReply:
                    result[obligation.messageID, default: []].insert(.pendingReply)
                case .confirmation:
                    result[obligation.messageID, default: []].insert(.confirmation)
                }
            }
    }
}
