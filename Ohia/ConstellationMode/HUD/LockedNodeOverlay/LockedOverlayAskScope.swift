import Foundation
import OhiaCore
import OhiaML

/// Computes the per-lens Ask scope when the locked-node overlay is open.
///
/// Returns the set of message ids that match the overlay's framing around
/// the locked message — the contact's participation in `.people`, the
/// overlapping project row in `.projects`, and otherwise the locked
/// message's own thread. The locked message itself is always included.
///
/// Predicates here mirror `LockedFrameContextPolicy` (which gates the
/// overlay's *visible* neighbour chips) but drop the small chip-display
/// limit and similarity-floor gates, so Ask retrieves from the full
/// in-scope pool rather than just what the overlay rendered.
///
/// Thread expansion (for `.people` and the default/meaning framing)
/// requires a SwiftData fetch, so the caller does it: `threadSeedIds`
/// returns the ids that should be expanded into their full threads.
nonisolated enum LockedOverlayAskScope {
    nonisolated static func inMemoryScope(
        frame: FrameKey,
        centerMessageId: String,
        centerRow: MessageFilterRow,
        messageIndex: [String: MessageFilterRow],
        userAddresses: Set<String>,
        projectsAllowedIDs: Set<String>? = nil
    ) -> Set<String> {
        var ids: Set<String> = [centerMessageId]
        switch frame.spatialLens {
        case .people:
            let correspondents = peopleCorrespondents(of: centerRow, userAddresses: userAddresses)
            guard !correspondents.isEmpty else { break }
            for (mid, row) in messageIndex {
                let participants = peopleParticipantSet(row: row, userAddresses: userAddresses)
                if !participants.isDisjoint(with: correspondents) {
                    ids.insert(mid)
                }
            }
        case .projects:
            // Plan settled default: Ask scope is explicit message ids from
            // the Projects snapshot (focused row, or full snapshot when no
            // row is focused), not semantic project-label overlap.
            if let projectsAllowedIDs, !projectsAllowedIDs.isEmpty {
                ids.formUnion(projectsAllowedIDs)
            }
        case .defaultFrame:
            // `.meaning` / `.defaultFrame`: thread expansion of the locked
            // message stands in for the semantic neighborhood without a
            // vector lookup in the hot path.
            break
        default:
            break
        }
        return ids
    }

    nonisolated static func threadSeedIds(
        frame: FrameKey,
        scope: Set<String>,
        centerMessageId: String
    ) -> Set<String> {
        switch frame.spatialLens {
        case .defaultFrame:
            return [centerMessageId]
        case .people:
            return scope
        default:
            return []
        }
    }

    /// The locked email's *focal contacts*: who the People-lens framing
    /// is "about". For sent mail the focal set is the recipients (the
    /// user is the implicit sender); for received mail it is the sender
    /// alone — CC recipients on inbound are intentionally excluded so
    /// we don't drift onto bystanders who happened to be CC'd. Mirrors
    /// `LockedFrameContextPolicy.correspondentSet`.
    private nonisolated static func peopleCorrespondents(
        of row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> Set<String> {
        let raw: [String] = row.isSentByUser
            ? row.recipientAddresses
            : [row.fromAddress]
        var set: Set<String> = []
        for value in raw {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty, !userAddresses.contains(normalized) {
                set.insert(normalized)
            }
        }
        return set
    }

    private nonisolated static func peopleParticipantSet(
        row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> Set<String> {
        let raw: [String] = row.isSentByUser
            ? row.recipientAddresses
            : [row.fromAddress] + row.recipientAddresses
        var set: Set<String> = []
        for value in raw {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty, !userAddresses.contains(normalized) {
                set.insert(normalized)
            }
        }
        return set
    }
}
