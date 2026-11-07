import Foundation
import OhiaCore
import OhiaML

enum ActionFilterPolicy {
    nonisolated static func replyMatches(
        _ criterion: AttentionFilterCriterion,
        needsReply: Bool?,
        isReplied: Bool
    ) -> Bool {
        switch criterion {
        case .any:
            return true
        case .required:
            return needsReply == true
        case .excluded:
            return isReplied == false
        }
    }

    nonisolated static func confirmationMatches(
        _ criterion: AttentionFilterCriterion,
        needsConfirmation: Bool?,
        isConfirmed: Bool
    ) -> Bool {
        switch criterion {
        case .any:
            return true
        case .required:
            return needsConfirmation == true
        case .excluded:
            return isConfirmed == false
        }
    }

    nonisolated static func resolutionMatches(
        _ criterion: AttentionFilterCriterion?,
        isResolved: Bool
    ) -> Bool {
        switch criterion ?? .any {
        case .any:
            return true
        case .required, .excluded:
            return isResolved == false
        }
    }
}

enum ConstellationMessageFilter {
    nonisolated static func matches(
        _ row: MessageFilterRow,
        filter: VectorFilter,
        includeHeadlineFlags: Bool = true
    ) -> Bool {
        if let accountIds = filter.accountIds {
            guard let rowAccountId = row.accountId else { return false }
            if !accountIds.contains(rowAccountId) { return false }
        }
        if let types = filter.messageTypes, !types.contains(row.messageType) { return false }
        if let reads = filter.readStates, !reads.contains(row.isRead) { return false }
        if let replies = filter.repliedStates, !replies.contains(row.isReplied) { return false }
        if let sentStates = filter.sentStates, !sentStates.contains(row.isSentByUser) { return false }
        if filter.flaggedOnly, !row.flagged { return false }
        if filter.hasAttachmentsOnly, !row.hasAttachments { return false }

        // Action criteria use the same three-state language across all chips:
        // grey shows both states, yellow shows mail still needing the action,
        // and red excludes mail where the action is complete.
        if includeHeadlineFlags {
            if !ActionFilterPolicy.replyMatches(
                filter.replyNeededCriterion,
                needsReply: row.isActionable,
                isReplied: row.isReplied
            ) {
                return false
            }
            if !ActionFilterPolicy.confirmationMatches(
                filter.confirmationNeededCriterion,
                needsConfirmation: row.requiresConfirmation,
                isConfirmed: row.isConfirmed
            ) {
                return false
            }
            if !ActionFilterPolicy.resolutionMatches(
                filter.resolvedCriterion,
                isResolved: row.isResolved
            ) {
                return false
            }
        }

        if !flatCategoryMatches(row, filter: filter) {
            return false
        }

        let correspondentNeedle = filter.correspondentQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !correspondentNeedle.isEmpty {
            var matches = false
            if filter.correspondentScopes.contains(.from) {
                let hay = row.fromAddress.lowercased() + " " + (row.fromName ?? "").lowercased()
                matches = hay.contains(correspondentNeedle)
            }
            if !matches, filter.correspondentScopes.contains(.to) {
                matches = row.toAddresses.contains { $0.contains(correspondentNeedle) }
                    || row.toNames.contains { $0.contains(correspondentNeedle) }
            }
            if !matches, filter.correspondentScopes.contains(.cc) {
                matches = row.ccAddresses.contains { $0.contains(correspondentNeedle) }
                    || row.ccNames.contains { $0.contains(correspondentNeedle) }
            }
            if !matches, filter.correspondentScopes.contains(.bcc) {
                matches = row.bccAddresses.contains { $0.contains(correspondentNeedle) }
                    || row.bccNames.contains { $0.contains(correspondentNeedle) }
            }
            if !matches { return false }
        }

        if let clusterIds = filter.clusterIds {
            guard let cid = row.clusterId, clusterIds.contains(cid) else { return false }
        }
        // Mailing-list scope: only rows from the selected list identities
        // render. Rows without a listId never match an active list filter.
        if let listIds = filter.listIds {
            guard let listId = row.listId, listIds.contains(listId) else { return false }
        }
        if !TriStateFilters.taskStatePasses(
            filter.taskState,
            tasks: row.dimensions?.tasks.map { $0 as any TaskAssigneeProvider }
        ) { return false }
        if !TriStateFilters.deadlineStatePasses(
            filter.deadlineState,
            deadlines: row.dimensions?.deadlines.map { $0 as any DeadlineTypeProvider }
        ) { return false }
        return true
    }

    private nonisolated static func flatCategoryMatches(
        _ row: MessageFilterRow,
        filter: VectorFilter
    ) -> Bool {
        let isRestState = filter.purposes == nil
            && filter.mailingListCategoryIncluded == nil
            && filter.customCategoryKeys == nil
        if isRestState { return true }

        let selectedPurposes = filter.purposes ?? Set(MailPurpose.allCases)
        let purposeMatches = row.purpose.map(selectedPurposes.contains) ?? false
        let listMatches = (filter.mailingListCategoryIncluded ?? true)
            && row.listId?.isEmpty == false
        let customMatches: Bool
        if let selectedCustom = filter.customCategoryKeys {
            customMatches = !selectedCustom.isEmpty
                && !row.customCategoryKeys.isDisjoint(with: selectedCustom)
        } else {
            customMatches = !row.customCategoryKeys.isEmpty
        }
        return purposeMatches || listMatches || customMatches
    }

    struct ClassificationCounts: Sendable {
        var purposes: [MailPurpose: Int] = [:]
        var mailingLists: Int = 0
        var custom: [String: Int] = [:]

        nonisolated init(
            purposes: [MailPurpose: Int] = [:],
            mailingLists: Int = 0,
            custom: [String: Int] = [:]
        ) {
            self.purposes = purposes
            self.mailingLists = mailingLists
            self.custom = custom
        }
    }

    /// Per-facet populations under every non-classification restriction.
    nonisolated static func classificationCounts(
        rows: [MessageFilterRow],
        filter: VectorFilter
    ) -> ClassificationCounts {
        var stripped = filter
        stripped.purposes = nil
        stripped.mailingListCategoryIncluded = nil
        stripped.customCategoryKeys = nil
        var counts = ClassificationCounts()
        for row in rows where matches(row, filter: stripped) {
            if let purpose = row.purpose {
                counts.purposes[purpose, default: 0] += 1
            }
            if row.listId?.isEmpty == false {
                counts.mailingLists += 1
            }
            for key in row.customCategoryKeys {
                counts.custom[key, default: 0] += 1
            }
        }
        return counts
    }

    struct VoicesCounts: Sendable, Equatable {
        /// Keyed by trimmed, lowercased address, the same key the Voices
        /// autocomplete uses for `CorrespondentFilterSuggestion.value`.
        var byAddress: [String: Int] = [:]
        /// Keyed by account, then list identity: a Lists row selects both.
        var byAccountList: [UUID: [String: Int]] = [:]

        nonisolated init(
            byAddress: [String: Int] = [:],
            byAccountList: [UUID: [String: Int]] = [:]
        ) {
            self.byAddress = byAddress
            self.byAccountList = byAccountList
        }
    }

    /// In-scope populations for the Voices autocomplete and Lists rows: how
    /// many messages each correspondent or mailing list would show if it were
    /// picked, under every other active filter and `filter.timeRange` (pass
    /// the scene's effective filter so rolling presets use the current
    /// window).
    ///
    /// - Correspondents: picking a suggestion replaces only the query, so a
    ///   correspondent counts under the current account scope, in the header
    ///   roles the search is set to, once per message. The filter matches
    ///   the query as a substring of each searched address, so an address
    ///   that occurs inside another (`ann@x.com` in `joann@x.com`) also
    ///   counts the broader address's messages. Display names, which the
    ///   filter searches too, are not consulted.
    /// - Lists: picking a list also switches the account scope to the list's
    ///   account (`VoicesMailingListFilter.selecting`), so each list counts
    ///   under its own account rather than the current one.
    ///
    /// Returns nil only when `checksCancellation` observes a cancelled task.
    nonisolated static func voicesCounts(
        rows: [MessageFilterRow],
        filter: VectorFilter,
        checksCancellation: Bool = false
    ) -> VoicesCounts? {
        var sharedFilter = filter
        sharedFilter.correspondentQuery = ""
        sharedFilter.listIds = nil
        sharedFilter.accountIds = nil
        let accountIds = filter.accountIds
        let scopes = filter.correspondentScopes
        var counts = VoicesCounts()
        var correspondentRows: [[String]] = []
        var addresses = Set<String>()
        for (offset, row) in rows.enumerated() {
            if checksCancellation, offset % 4_096 == 0, Task.isCancelled { return nil }
            if let timeRange = filter.timeRange {
                guard let receivedAt = row.receivedAt, timeRange.contains(receivedAt) else { continue }
            }
            guard matches(row, filter: sharedFilter) else { continue }
            if let listId = row.listId, !listId.isEmpty, let accountId = row.accountId {
                counts.byAccountList[accountId, default: [:]][listId, default: 0] += 1
            }
            if let accountIds {
                guard let accountId = row.accountId, accountIds.contains(accountId) else { continue }
            }
            addresses.removeAll(keepingCapacity: true)
            if scopes.contains(.from) {
                addresses.insert(voicesAddressKey(row.fromAddress))
            }
            if scopes.contains(.to) {
                for address in row.toAddresses { addresses.insert(voicesAddressKey(address)) }
            }
            if scopes.contains(.cc) {
                for address in row.ccAddresses { addresses.insert(voicesAddressKey(address)) }
            }
            if scopes.contains(.bcc) {
                for address in row.bccAddresses { addresses.insert(voicesAddressKey(address)) }
            }
            addresses.remove("")
            for address in addresses {
                counts.byAddress[address, default: 0] += 1
            }
            correspondentRows.append(Array(addresses))
        }

        // Exact counts already equal the filter's substring match for every
        // address that occurs inside no other address. Recount the rest.
        let containedAddresses = addressesContainedInOthers(Set(counts.byAddress.keys))
        guard containedAddresses.isEmpty == false else { return counts }
        var substringCounts: [String: Int] = [:]
        for (offset, rowAddresses) in correspondentRows.enumerated() {
            if checksCancellation, offset % 4_096 == 0, Task.isCancelled { return nil }
            for needle in containedAddresses where rowAddresses.contains(where: { $0.contains(needle) }) {
                substringCounts[needle, default: 0] += 1
            }
        }
        counts.byAddress.merge(substringCounts) { _, substringCount in substringCount }
        return counts
    }

    nonisolated static func voicesAddressKey(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Addresses that occur inside another address of the set. With one "@"
    /// in each, `a` occurs inside `b` exactly when b's local part ends with
    /// a's and b's domain starts with a's, so indexing by local part keeps
    /// this proportional to the total length of the local parts. Addresses
    /// without exactly one "@" are left out.
    nonisolated static func addressesContainedInOthers(_ addresses: Set<String>) -> Set<String> {
        func split(_ address: String) -> (local: Substring, domain: Substring)? {
            guard let at = address.firstIndex(of: "@") else { return nil }
            let domain = address[address.index(after: at)...]
            guard domain.contains("@") == false else { return nil }
            return (address[..<at], domain)
        }
        var byLocalPart: [Substring: [(address: String, domain: Substring)]] = [:]
        for address in addresses {
            guard let parts = split(address) else { continue }
            byLocalPart[parts.local, default: []].append((address, parts.domain))
        }
        var contained = Set<String>()
        for address in addresses {
            guard let parts = split(address) else { continue }
            var start = parts.local.startIndex
            while true {
                for candidate in byLocalPart[parts.local[start...]] ?? []
                where candidate.address != address && parts.domain.hasPrefix(candidate.domain) {
                    contained.insert(candidate.address)
                }
                guard start < parts.local.endIndex else { break }
                start = parts.local.index(after: start)
            }
        }
        return contained
    }

    /// Convenience overload for `@MainActor` callers (UI, tests). Resolves
    /// each preset's window via `TimeRangePreset.range(relativeTo:)` — which
    /// is `@MainActor`-isolated under this project's default-isolation
    /// setting — then delegates to the nonisolated counter so the heavy
    /// per-row work can run from anywhere (e.g. inside a detached task
    /// after the caller has resolved windows on the main actor).
    static func timeRangeCounts(
        rows: [MessageFilterRow],
        filter: VectorFilter,
        presets: [TimeRangePreset],
        now: Date = .now,
        customRange: ClosedRange<Date>? = nil
    ) -> [TimeRangePreset: Int] {
        let windows = resolveTimeRangeWindows(
            presets: presets,
            now: now,
            customRange: customRange
        )
        return timeRangeCounts(rows: rows, filter: filter, windowsByPreset: windows)
    }

    /// Resolves the lookup table the nonisolated counter consumes. `.all`
    /// maps to `.some(nil)` (no upper bound — every row matches). `.custom`
    /// is included only when a real range was supplied; otherwise the key
    /// is omitted and the view renders the `Custom…` row without a count.
    static func resolveTimeRangeWindows(
        presets: [TimeRangePreset],
        now: Date = .now,
        customRange: ClosedRange<Date>? = nil
    ) -> [TimeRangePreset: ClosedRange<Date>?] {
        var windows: [TimeRangePreset: ClosedRange<Date>?] = [:]
        for preset in presets {
            switch preset {
            case .all:
                windows[preset] = .some(nil)
            case .custom:
                if let customRange {
                    windows[preset] = .some(customRange)
                }
            default:
                if let range = preset.range(relativeTo: now) {
                    windows[preset] = .some(range)
                }
            }
        }
        return windows
    }

    /// Per-preset counts of messages that would render if each time-range
    /// preset were selected. Every other filter is applied normally; the
    /// preset's window is layered on top of `row.receivedAt`. Windows are
    /// passed in pre-resolved so this function stays `nonisolated` and can
    /// run inside a detached task without hopping back to MainActor.
    nonisolated static func timeRangeCounts(
        rows: [MessageFilterRow],
        filter: VectorFilter,
        windowsByPreset: [TimeRangePreset: ClosedRange<Date>?]
    ) -> [TimeRangePreset: Int] {
        // Strip `timeRange` from the captured filter so callers can pass a
        // filter whose `timeRange` already reflects the currently-selected
        // preset without double-filtering each row against it.
        var stripped = filter
        stripped.timeRange = nil
        // Intentionally not pre-seeded with zero entries — the view treats
        // an empty dict as "not yet computed" and falls back to plain row
        // labels. A preset whose window legitimately holds zero rows after
        // the compute completes is simply absent from the result and the
        // view renders `"(0)"` via the `counts[preset] ?? 0` path.
        var counts: [TimeRangePreset: Int] = [:]
        for row in rows where matches(row, filter: stripped) {
            for (preset, window) in windowsByPreset {
                if let window {
                    guard let received = row.receivedAt else { continue }
                    if window.contains(received) {
                        counts[preset, default: 0] += 1
                    }
                } else {
                    counts[preset, default: 0] += 1
                }
            }
        }
        return counts
    }
}
