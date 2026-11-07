import Foundation
import OhiaCore

enum PeopleRingMessageScope {
    nonisolated static func scopedMessageIds(
        involving email: String,
        filter: VectorFilter,
        messageIndex: [String: MessageFilterRow],
        userAddresses: Set<String>
    ) -> Set<String> {
        let normalized = normalizedEmail(email)
        guard !normalized.isEmpty else { return [] }
        let normalizedUsers = Set(userAddresses.map(normalizedEmail).filter { !$0.isEmpty })
        return Set(messageIndex.compactMap { messageId, row in
            guard ConstellationMessageFilter.matches(row, filter: filter),
                  timeRangeContains(row, filter: filter),
                  LockedFrameContextPolicy.peopleParticipantSet(
                    row: row,
                    userAddresses: normalizedUsers
                  ).contains(normalized) else {
                return nil
            }
            return messageId
        })
    }

    nonisolated static func resolvedMessageIds(
        for email: String?,
        capturedIds: Set<String>?,
        in hubs: [PersonHubInstance],
        isPeopleLensActive: Bool,
        fallbackIds: () -> Set<String>
    ) -> Set<String> {
        guard let email,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        if let visibleIds = visibleHubMessageIds(for: email, in: hubs) {
            return visibleIds
        }
        if isPeopleLensActive {
            return []
        }
        if let capturedIds, !capturedIds.isEmpty {
            return capturedIds
        }
        return fallbackIds()
    }

    nonisolated static func focusedSceneMessageIds(
        for email: String?,
        capturedIds: Set<String>?,
        in hubs: [PersonHubInstance],
        fallbackIds: () -> Set<String>
    ) -> Set<String> {
        guard let email,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        if let capturedIds, !capturedIds.isEmpty {
            return capturedIds
        }
        if let visibleIds = visibleHubMessageIds(for: email, in: hubs) {
            return visibleIds
        }
        return fallbackIds()
    }

    nonisolated static func focusCaptureMessageIds(
        visibleHubIds: Set<String>,
        fullScopeIds: Set<String>
    ) -> Set<String> {
        if !fullScopeIds.isEmpty {
            return fullScopeIds
        }
        return visibleHubIds
    }

    nonisolated static func visibleHubMessageIds(
        for email: String,
        in hubs: [PersonHubInstance]
    ) -> Set<String>? {
        let target = normalizedEmail(email)
        guard !target.isEmpty else { return nil }
        return hubs.first { normalizedEmail($0.email) == target }?.messageIds
    }

    nonisolated static func normalizedEmail(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mailto:") {
            trimmed.removeFirst("mailto:".count)
        }
        return trimmed
    }

    nonisolated private static func timeRangeContains(
        _ row: MessageFilterRow,
        filter: VectorFilter
    ) -> Bool {
        guard let timeRange = filter.timeRange else { return true }
        guard let receivedAt = row.receivedAt else { return false }
        return timeRange.contains(receivedAt)
    }

    /// Every correspondent's scope in one pass over `messageIndex`: the
    /// same filter, time-range, and participant rules as `scopedMessageIds`,
    /// grouped by normalized participant address. Returns `nil` only when
    /// `checksCancellation` observes a cancelled task.
    nonisolated static func correspondentScopeIndex(
        filter: VectorFilter,
        messageIndex: [String: MessageFilterRow],
        userAddresses: Set<String>,
        checksCancellation: Bool = false
    ) -> PeopleCorrespondentScopeIndex? {
        let normalizedUsers = Set(userAddresses.map(normalizedEmail).filter { !$0.isEmpty })
        var messageIdsByCorrespondent: [String: Set<String>] = [:]
        var visited = 0
        for (messageId, row) in messageIndex {
            visited += 1
            if checksCancellation, visited % 4_096 == 0, Task.isCancelled { return nil }
            guard ConstellationMessageFilter.matches(row, filter: filter),
                  timeRangeContains(row, filter: filter) else {
                continue
            }
            for participant in LockedFrameContextPolicy.peopleParticipantSet(
                row: row,
                userAddresses: normalizedUsers
            ) {
                messageIdsByCorrespondent[participant, default: []].insert(messageId)
            }
        }
        return PeopleCorrespondentScopeIndex(messageIdsByCorrespondent: messageIdsByCorrespondent)
    }
}

/// Filtered message scope of every correspondent, built off the main actor
/// per People scene refresh. `messageIds(involving:)` returns exactly what
/// `PeopleRingMessageScope.scopedMessageIds(involving:...)` returns for the
/// filter, index, and user addresses the index was built from, without
/// rescanning the message index.
nonisolated struct PeopleCorrespondentScopeIndex: Sendable {
    private let messageIdsByCorrespondent: [String: Set<String>]

    init(messageIdsByCorrespondent: [String: Set<String>]) {
        self.messageIdsByCorrespondent = messageIdsByCorrespondent
    }

    func messageIds(involving email: String) -> Set<String> {
        let normalized = PeopleRingMessageScope.normalizedEmail(email)
        guard !normalized.isEmpty else { return [] }
        return messageIdsByCorrespondent[normalized] ?? []
    }
}

/// The live scene inputs a correspondent scope is a function of: the frame,
/// filter, and Moments preset (which resolve to the visual filter), the
/// user's addresses, and the message index — identified by the snapshot
/// cache's content revision and the arrival gate, exactly as
/// `currentMessageIndex` is.
struct PeopleCorrespondentScopeInputs: Equatable {
    let frame: FrameKey
    let filter: VectorFilter
    let selectedTimeRange: TimeRangePreset
    let userAddresses: Set<String>
    let snapshotRevision: UInt64
    let gate: NewMailArrivalVisibilityGate
}

/// A correspondent scope index together with the inputs it was built from.
struct PeopleCorrespondentScopeSnapshot {
    let inputs: PeopleCorrespondentScopeInputs
    /// The visual filter the index applied, with the Moments window
    /// resolved at build time.
    let visualFilter: VectorFilter
    let index: PeopleCorrespondentScopeIndex

    /// Whether the index answers for the live scene. Any change to the
    /// filter, Moments preset, user addresses, cached snapshot, or arrival
    /// gate retires it until a rebuild over the new inputs lands. A rolling
    /// Moments window keeps the bounds it had at build time, matching the
    /// packet built in the same refresh.
    func describes(_ live: PeopleCorrespondentScopeInputs) -> Bool {
        inputs == live
    }

    /// Whether a refresh resolving `visualFilter` from `live` would build the
    /// same index, so the rebuild can be skipped. A rolling Moments window
    /// resolves to new bounds on every refresh and is always rebuilt.
    func canServeRefresh(
        _ live: PeopleCorrespondentScopeInputs,
        visualFilter: VectorFilter
    ) -> Bool {
        inputs == live && self.visualFilter == visualFilter
    }
}
