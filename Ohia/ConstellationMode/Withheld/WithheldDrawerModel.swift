import AppKit
import Foundation
import SwiftData
import OhiaCore
import OhiaMail
import OhiaIngest
import OhiaScheduler

enum WithheldScope: String, CaseIterable, Identifiable { case all, junk, trash
    var id: String { rawValue }
    func includes(_ f: WithheldFolderRole) -> Bool {
        switch self { case .all: return true; case .junk: return f == .junk; case .trash: return f == .trash }
    }
}
enum WithheldSort: String, CaseIterable, Identifiable { case date, sender, spam, subject; var id: String { rawValue } }

/// One selectable account in the drawer's account-scope pulldown. Populated at load
/// time (Task 8); empty means "all accounts" is the only option.
struct WithheldAccountOption: Identifiable, Hashable {
    let id: UUID
    /// The account's short display name (e.g. "University"), matching the TopBar
    /// Destination section — not the raw email address.
    let name: String
    /// The account's palette index, so the drawer can tint the chip in the
    /// account color (via AccountColorPalette) the same way the TopBar does.
    let colorIndex: Int?
}

protocol WithheldFolderFetching: Sendable {
    func fetchRecent(
        role: WithheldFolderRole,
        config: WithheldFetchConfig,
        now: Date
    ) async throws -> [WithheldRow]
    func fetchBody(
        uid: UInt32,
        expectedUIDValidity: UInt32?,
        role: WithheldFolderRole,
        config: WithheldFetchConfig
    ) async throws -> Data
    func searchOlder(
        role: WithheldFolderRole,
        config: WithheldFetchConfig,
        query: String
    ) async throws -> [WithheldRow]
}

extension WithheldFolderService: WithheldFolderFetching {}

typealias WithheldFetchConfigResolver = @MainActor (Account, OAuthTokenStore) async throws -> WithheldFetchConfig?

@MainActor
@Observable
final class WithheldDrawerModel {
    var rows: [WithheldRow] = [] {
        didSet {
            pruneSelectionToCurrentRows()
            rebuildSpamFeedbackScores()
        }
    }
    var scope: WithheldScope = .all
    var sort: WithheldSort = .date
    var query: String = ""
    var unreadOnly = false
    var attachmentsOnly = false
    var accountFilter: UUID? = nil
    /// Opened detail row. This stays distinct from the multi-selection set:
    /// single-click selects; double-click opens the detail.
    var selectedID: String? = nil
    var selectedRowIDs: Set<String> = []
    var selectionAnchorID: String? = nil

    /// Accounts available to scope by (drawer pulldown); populated during load.
    var accountOptions: [WithheldAccountOption] = []
    /// Decoded body text per row id, filled on demand when a row's detail opens.
    var bodyTextByID: [String: String] = [:]
    /// The row whose body fetch is currently in flight (drives the detail spinner).
    var bodyLoadingID: String? = nil
    /// Per-account load failures, surfaced honestly in the drawer rather than hidden.
    var loadErrors: [UUID: String] = [:]
    /// The row whose promotion (Not Junk / Restore) is currently in flight, driving
    /// the button's inline spinner. Only one promotion runs at a time.
    var promotingID: String? = nil
    /// Per-row promotion failures, surfaced inline under the promote button.
    var promoteErrors: [String: String] = [:]

    /// Lowercased addresses of people in the corpus (correspondents and their
    /// linked alternate addresses). Drives the "From a known contact" rescue
    /// hint. Rebuilt from SwiftData at each `load`.
    private(set) var knownSenderAddresses: Set<String> = []
    /// Account-scoped subscription keys (`WithheldSignals.subscriptionKey`) for
    /// currently-subscribed mailing lists. Keyed by `(accountID, listId)` since
    /// list identities never cross accounts. Drives the "Subscribed list" rescue
    /// hint. Rebuilt from SwiftData at each `load`.
    private(set) var subscribedListKeys: Set<String> = []
    /// Local spam/ham feedback derived from existing mailbox mutation rows:
    /// moveToJunk = user spam signal, moveToInbox from Junk = user ham signal.
    private(set) var mailboxSpamFeedbackSignals: [MailboxSpamFeedbackSignal] = [] {
        didSet { rebuildSpamFeedbackScores() }
    }
    private(set) var spamFeedbackScoresByRowID: [String: MailboxSpamFeedbackScore] = [:]
    /// Reference instant for recency decay when scoring spam/ham feedback. Set to
    /// the active load/refresh `now` so scoring is deterministic under injected
    /// time; defaults to the current date for live use.
    private var spamScoringReferenceDate = Date()

    /// Transient IMAP reader (never ingests). One per model instance.
    private let service: any WithheldFolderFetching
    private let promotionBodySource: any WithheldPromotionBodySource
    private let resolveFetchConfig: WithheldFetchConfigResolver
    private let cancellationRetryDelay: Duration
    private var pendingLoadRequest: WithheldLoadRequest?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Resolved fetch configs by account id, reused for body peeks and server search.
    private var configsByAccount: [UUID: WithheldFetchConfig] = [:]
    /// In-flight guards so reopening the drawer (or re-submitting search) mid-fetch
    /// doesn't spin up overlapping transient IMAP sessions. Observed so the view can
    /// surface load / search progress; the reentrancy-guard use is unchanged.
    private(set) var isLoading = false
    private(set) var isSearching = false

    init(
        service: any WithheldFolderFetching = WithheldFolderService(),
        promotionBodySource: any WithheldPromotionBodySource = WithheldFolderServiceBodySource(service: WithheldFolderService()),
        resolveFetchConfig: @escaping WithheldFetchConfigResolver = WithheldDrawerModel.defaultFetchConfig,
        cancellationRetryDelay: Duration = .milliseconds(250)
    ) {
        self.service = service
        self.promotionBodySource = promotionBodySource
        self.resolveFetchConfig = resolveFetchConfig
        self.cancellationRetryDelay = cancellationRetryDelay
    }

    /// The selected row, resolved against the *visible* set so it disappears when
    /// filtered out from under the detail view.
    var selectedRow: WithheldRow? { visibleRows.first { $0.id == selectedID } }

    var selectedRows: [WithheldRow] {
        visibleRows.filter { selectedRowIDs.contains($0.id) }
    }

    func isSelected(_ id: String) -> Bool {
        selectedRowIDs.contains(id)
    }

    func selectOnly(_ id: String?) {
        if let id {
            selectedRowIDs = [id]
            selectionAnchorID = id
        } else {
            clearSelection()
        }
    }

    func toggleSelection(_ id: String, orderedIDs: [String]) {
        if selectedRowIDs.contains(id) {
            selectedRowIDs.remove(id)
            if selectionAnchorID == id {
                selectionAnchorID = orderedIDs.last(where: { selectedRowIDs.contains($0) })
            }
        } else {
            selectedRowIDs.insert(id)
            selectionAnchorID = id
        }
        if selectedRowIDs.isEmpty { selectionAnchorID = nil }
    }

    func extendSelection(to id: String, in orderedIDs: [String]) {
        guard let anchor = selectionAnchorID,
              let anchorIndex = orderedIDs.firstIndex(of: anchor),
              let targetIndex = orderedIDs.firstIndex(of: id) else {
            selectOnly(id)
            return
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        selectedRowIDs = Set(orderedIDs[lower...upper])
    }

    func clearSelection() {
        selectedRowIDs = []
        selectionAnchorID = nil
    }

    func selectAllVisible() {
        let ids = visibleRows.map(\.id)
        selectedRowIDs = Set(ids)
        selectionAnchorID = ids.first
    }

    /// Modifier-aware mouse-down selection for the ledger. Shift extends ranges;
    /// command/control toggles membership. A plain mouse-down on an already-
    /// selected row keeps the selection stable so dragging can still carry the
    /// selected set; the row clears selection only after the tap completes.
    func handleSelectionClick(
        id: String,
        modifiers: NSEvent.ModifierFlags,
        orderedIDs: [String]
    ) {
        if modifiers.contains(.shift) {
            extendSelection(to: id, in: orderedIDs)
        } else if modifiers.contains(.command) || modifiers.contains(.control) {
            toggleSelection(id, orderedIDs: orderedIDs)
        } else if selectedRowIDs.contains(id) {
            selectionAnchorID = id
        } else {
            selectOnly(id)
        }
    }

    /// Right-clicking one selected row in a multi-selection acts on the whole
    /// visible selection; right-clicking any other row collapses to that row.
    func actionRows(startingAt row: WithheldRow) -> [WithheldRow] {
        let selected = selectedRows
        if selectedRowIDs.contains(row.id), selected.count >= 2 {
            return selected
        }
        selectOnly(row.id)
        return [row]
    }

    /// Dragging a selected row drags the selected set; dragging an unselected
    /// row exports only that row.
    func dragRowIDs(startingAt row: WithheldRow) -> [String] {
        if selectedRowIDs.contains(row.id), selectedRowIDs.count >= 2 {
            return visibleRows.map(\.id).filter { selectedRowIDs.contains($0) }
        }
        return [row.id]
    }

    func rows(matching ids: [String]) -> [WithheldRow] {
        let idSet = Set(ids)
        return visibleRows.filter { idSet.contains($0.id) }
    }

    func applyReadState(rowIDs: Set<String>, isRead: Bool) {
        guard !rowIDs.isEmpty else { return }
        rows = rows.map { row in
            guard rowIDs.contains(row.id), row.isRead != isRead else { return row }
            return row.copy(isRead: isRead)
        }
    }

    func removeRows(rowIDs: Set<String>) {
        guard !rowIDs.isEmpty else { return }
        rows.removeAll { rowIDs.contains($0.id) }
        for id in rowIDs { promoteErrors[id] = nil }
        if let selectedID, rowIDs.contains(selectedID) { self.selectedID = nil }
        selectedRowIDs.subtract(rowIDs)
        if let anchor = selectionAnchorID, rowIDs.contains(anchor) {
            selectionAnchorID = visibleRows.last(where: { selectedRowIDs.contains($0.id) })?.id
        }
        if selectedRowIDs.isEmpty { selectionAnchorID = nil }
    }

    /// Non-sort filtering (scope + account + unread + attachments + query) shared by
    /// `visibleRows` and `count(for:)`. Parameterized by scope so the chip counts can
    /// be computed per scope under the currently-active non-scope filters.
    private func filteredRows(scope: WithheldScope) -> [WithheldRow] {
        var r = rows.filter { scope.includes($0.folder) }
        if let acct = accountFilter { r = r.filter { $0.accountID == acct } }
        if unreadOnly { r = r.filter { !$0.isRead } }
        if attachmentsOnly { r = r.filter(\.hasAttachments) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            r = r.filter { $0.sender.lowercased().contains(q) || $0.subject.lowercased().contains(q) }
        }
        return r
    }

    /// Count of rows that the given scope would show under the currently-active
    /// non-scope filters. By construction All == Junk + Trash.
    func count(for scope: WithheldScope) -> Int { filteredRows(scope: scope).count }

    var availableSorts: [WithheldSort] {
        var sorts = WithheldSort.allCases.filter { $0 != .spam }
        if filteredRows(scope: scope).contains(where: { effectiveSpamScore(for: $0) != nil }) {
            sorts.insert(.spam, at: 2)
        }
        return sorts
    }

    var effectiveSort: WithheldSort {
        sort == .spam && !availableSorts.contains(.spam) ? .date : sort
    }

    var visibleRows: [WithheldRow] {
        var r = filteredRows(scope: scope)
        switch effectiveSort {
        case .date: r.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .sender: r.sort { $0.sender.localizedCaseInsensitiveCompare($1.sender) == .orderedAscending }
        // nil sorts last regardless of sign: real (incl. negative SpamAssassin ham) scores rank above unknown.
        case .spam: r.sort { (effectiveSpamScore(for: $0) ?? -.infinity) > (effectiveSpamScore(for: $1) ?? -.infinity) }
        case .subject: r.sort { $0.subject.localizedCaseInsensitiveCompare($1.subject) == .orderedAscending }
        }
        return r
    }

    // MARK: - Rescue signals (corpus-derived row hints)

    /// Plain-language rescue hint for a row, resolved against the corpus signals
    /// captured at load. When the drawer is sorted by spam score, append the
    /// underlying header score so the visible row explains the current ordering.
    func ledgerLine(for row: WithheldRow) -> String? {
        WithheldSignals.ledgerLine(
            for: row,
            knownSenderAddresses: knownSenderAddresses,
            subscribedListKeys: subscribedListKeys,
            spamFeedbackScore: spamFeedbackScore(for: row),
            effectiveSpamScore: effectiveSpamScore(for: row),
            revealsSpamScore: effectiveSort == .spam
        )
    }

    func spamFeedbackScore(for row: WithheldRow) -> MailboxSpamFeedbackScore? {
        spamFeedbackScoresByRowID[row.id]
    }

    func effectiveSpamScore(for row: WithheldRow) -> Double? {
        let feedback = spamFeedbackScore(for: row)
        guard let providerScore = row.spamScore else {
            return feedback?.hasEvidence == true ? feedback?.adjustment : nil
        }
        return providerScore + (feedback?.adjustment ?? 0)
    }

    func replaceMailboxSpamFeedbackSignalsForTesting(_ signals: [MailboxSpamFeedbackSignal]) {
        mailboxSpamFeedbackSignals = signals
    }

    func refreshRescueSignalsForTesting(from context: ModelContext, now: Date = Date()) {
        rebuildRescueSignals(from: context, now: now)
    }

    /// One batched read at load: build the known-correspondent address set and
    /// the subscribed-list key set. Bounded fetches (correspondents/lists are
    /// deduplicated entities, not per-message rows), cached for O(1) per-row use.
    /// The correspondent fetch prefetches `linkedParticipants` so collecting
    /// alternate addresses stays a single round-trip rather than an N+1 fault.
    private func rebuildRescueSignals(from context: ModelContext, now: Date) {
        spamScoringReferenceDate = now
        var known = Set<String>()
        var correspondentFetch = FetchDescriptor<Correspondent>()
        correspondentFetch.relationshipKeyPathsForPrefetching = [\Correspondent.linkedParticipants]
        if let correspondents = try? context.fetch(correspondentFetch) {
            for correspondent in correspondents {
                known.insert(correspondent.primaryEmail.lowercased())
                for participant in correspondent.linkedParticipants {
                    known.insert(participant.emailAddress.lowercased())
                }
            }
        }
        knownSenderAddresses = known

        var subscribed = Set<String>()
        if let lists = try? context.fetch(FetchDescriptor<MailingList>()) {
            for list in lists where list.resolvedStatus(now: now) == MailingListStatus.subscribed {
                subscribed.insert(
                    WithheldSignals.subscriptionKey(
                        accountID: list.accountID,
                        listId: list.listId.lowercased()
                    )
                )
            }
        }
        subscribedListKeys = subscribed

        mailboxSpamFeedbackSignals = Self.fetchMailboxSpamFeedbackSignals(from: context)
    }

    private static func fetchMailboxSpamFeedbackSignals(from context: ModelContext) -> [MailboxSpamFeedbackSignal] {
        let targetSignalCount = 2_000
        let fetchBatchSize = 2_000
        let maxRowsScanned = 20_000
        var signals: [MailboxSpamFeedbackSignal] = []
        var offset = 0

        while signals.count < targetSignalCount, offset < maxRowsScanned {
            var mutationFetch = FetchDescriptor<MailboxMutation>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            mutationFetch.fetchLimit = fetchBatchSize
            mutationFetch.fetchOffset = offset
            guard let mutations = try? context.fetch(mutationFetch),
                  !mutations.isEmpty else {
                break
            }

            signals.append(contentsOf: mutations.compactMap(MailboxSpamFeedbackSignal.init))
            offset += mutations.count
            if mutations.count < fetchBatchSize {
                break
            }
        }

        return Array(signals.prefix(targetSignalCount))
    }

    private func rebuildSpamFeedbackScores() {
        guard !rows.isEmpty, !mailboxSpamFeedbackSignals.isEmpty else {
            spamFeedbackScoresByRowID = [:]
            return
        }

        var next: [String: MailboxSpamFeedbackScore] = [:]
        for row in rows {
            let evidence = MailboxSpamFeedbackEvidence(
                accountID: row.accountID,
                senderAddress: row.senderAddress,
                subject: row.subject,
                listId: row.listId
            )
            let score = MailboxSpamFeedbackScorer.score(
                evidence: evidence,
                against: mailboxSpamFeedbackSignals,
                now: spamScoringReferenceDate
            )
            if score.hasEvidence {
                next[row.id] = score
            }
        }
        spamFeedbackScoresByRowID = next
    }

    // MARK: - Live fetch (never ingests)

    /// Fetch recent Junk + Trash across the given accounts, transiently over IMAP.
    /// Per-account auth failures land in `loadErrors`; a missing Junk/Trash folder
    /// for one role is normal and not reported as a failure.
    func load(
        accounts: [Account],
        oauthStore: OAuthTokenStore,
        modelContext: ModelContext? = nil,
        now: Date = Date()
    ) async {
        let request = WithheldLoadRequest(
            accounts: accounts,
            oauthStore: oauthStore,
            modelContext: modelContext,
            now: now
        )

        if isLoading {
            pendingLoadRequest = request
            await waitForCurrentLoad()
            guard !Task.isCancelled, let pending = claimPendingLoadRequest() else { return }
            await runClaimedLoad(startingWith: pending)
            return
        }

        isLoading = true
        // Discard any orphaned request left behind by callers that were all
        // canceled before they could claim it.
        pendingLoadRequest = nil
        await runClaimedLoad(startingWith: request)
    }

    private func runClaimedLoad(startingWith initialRequest: WithheldLoadRequest) async {
        var request = initialRequest
        defer { finishCurrentLoad() }

        while true {
            if let modelContext = request.modelContext {
                rebuildRescueSignals(from: modelContext, now: request.now)
            }

            await loadAttempt(
                accounts: request.accounts,
                oauthStore: request.oauthStore,
                modelContext: request.modelContext,
                now: request.now,
                allowsCancellationRetry: true
            )

            guard !Task.isCancelled, let pending = pendingLoadRequest else { return }
            pendingLoadRequest = nil
            request = pending
        }
    }

    private func waitForCurrentLoad() async {
        await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
        }
    }

    private func claimPendingLoadRequest() -> WithheldLoadRequest? {
        guard !isLoading, let pending = pendingLoadRequest else { return nil }
        pendingLoadRequest = nil
        isLoading = true
        return pending
    }

    private func finishCurrentLoad() {
        isLoading = false
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func loadAttempt(
        accounts: [Account],
        oauthStore: OAuthTokenStore,
        modelContext: ModelContext?,
        now: Date,
        allowsCancellationRetry: Bool
    ) async {
        spamScoringReferenceDate = now
        var options: [WithheldAccountOption] = []
        var entries: [(id: UUID, config: WithheldFetchConfig)] = []
        var nextConfigsByAccount: [UUID: WithheldFetchConfig] = [:]
        var nextLoadErrors: [UUID: String] = [:]
        var sawCancellation = false

        for account in accounts {
            options.append(WithheldAccountOption(id: account.id, name: account.displayName, colorIndex: account.colorIndex))
            do {
                try Task.checkCancellation()
                guard let config = try await resolveFetchConfig(account, oauthStore) else { continue }
                nextConfigsByAccount[account.id] = config
                entries.append((account.id, config))
            } catch is CancellationError {
                sawCancellation = true
            } catch {
                nextLoadErrors[account.id] = "\(account.emailAddress): \(error.localizedDescription)"
            }
        }

        let svc = service
        var collected: [WithheldRow] = []
        var failures: [UUID: String] = [:]
        await withTaskGroup(of: WithheldLoadOutcome.self) { group in
            for entry in entries {
                for role in [WithheldFolderRole.junk, .trash] {
                    let cfg = entry.config
                    let id = entry.id
                    group.addTask {
                        do {
                            return .rows(try await svc.fetchRecent(role: role, config: cfg, now: now))
                        } catch is WithheldFolderService.ServiceError {
                            return .rows([])   // folderNotFound for this role is normal
                        } catch is CancellationError {
                            return .cancelled
                        } catch {
                            return .failure(id, error.localizedDescription)
                        }
                    }
                }
            }
            for await outcome in group {
                switch outcome {
                case .rows(let rows): collected.append(contentsOf: rows)
                case .cancelled: sawCancellation = true
                case .failure(let id, let message): failures[id] = message
                }
            }
        }

        if sawCancellation, allowsCancellationRetry, !Task.isCancelled {
            do {
                try await Task.sleep(for: cancellationRetryDelay)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await loadAttempt(
                accounts: accounts,
                oauthStore: oauthStore,
                modelContext: modelContext,
                now: now,
                allowsCancellationRetry: false
            )
            return
        }

        guard !Task.isCancelled else { return }
        guard !sawCancellation || !collected.isEmpty || !failures.isEmpty || !nextLoadErrors.isEmpty else {
            return
        }

        accountOptions = options
        configsByAccount = nextConfigsByAccount
        if let active = accountFilter, configsByAccount[active] == nil { accountFilter = nil }
        rows = mergedWithRetainedTrash(collected, modelContext: modelContext)
        loadErrors = nextLoadErrors
        for (id, message) in failures where loadErrors[id] == nil { loadErrors[id] = message }
    }

    /// The provider drawer is also Ohia's durable Trash surface. Merge every
    /// retained local Trash row into the transient provider results so the
    /// messages and failed/offline IMAP moves remain restorable after relaunch.
    /// A matching provider Trash copy donates its live UID coordinates while
    /// keeping the local UUID as the stable row identity.
    private func mergedWithRetainedTrash(
        _ providerRows: [WithheldRow],
        modelContext: ModelContext?
    ) -> [WithheldRow] {
        guard let modelContext else { return providerRows }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.trashedAt != nil }
        )
        guard let retainedMessages = try? modelContext.fetch(descriptor),
              !retainedMessages.isEmpty else {
            return providerRows
        }

        var merged = providerRows
        var matchedMessageIDs = Set<UUID>()
        var matchedProviderIndices = Set<Int>()

        // Message-ID is authoritative only when it identifies exactly one row
        // on each side. This avoids silently attaching duplicate provider copies
        // or duplicate retained rows to an arbitrary local identity.
        var exactProvidersByMessage: [UUID: [Int]] = [:]
        var exactMessagesByProvider: [Int: [UUID]] = [:]
        for message in retainedMessages {
            guard let accountID = message.accountID ?? message.account?.id,
                  let header = canonicalProviderMessageID(message.messageIdHeader) else {
                continue
            }
            for index in merged.indices {
                let row = merged[index]
                guard row.localMessageID == nil,
                      row.folder == .trash,
                      row.accountID == accountID,
                      canonicalProviderMessageID(row.messageId) == header else {
                    continue
                }
                exactProvidersByMessage[message.id, default: []].append(index)
                exactMessagesByProvider[index, default: []].append(message.id)
            }
        }
        for message in retainedMessages {
            guard let candidates = exactProvidersByMessage[message.id],
                  candidates.count == 1,
                  let providerIndex = candidates.first,
                  exactMessagesByProvider[providerIndex]?.count == 1 else {
                continue
            }
            merged[providerIndex] = merged[providerIndex].copy(localMessageID: message.id)
            matchedMessageIDs.insert(message.id)
            matchedProviderIndices.insert(providerIndex)
        }

        // Headerless mail gets a conservative envelope fallback. Never use it
        // to override two contradictory Message-ID values, and only accept a
        // unique one-to-one candidate across both provider and retained sets.
        var envelopeProvidersByMessage: [UUID: [Int]] = [:]
        var envelopeMessagesByProvider: [Int: [UUID]] = [:]
        for message in retainedMessages where !matchedMessageIDs.contains(message.id) {
            guard let accountID = message.accountID ?? message.account?.id else { continue }
            let messageHeader = canonicalProviderMessageID(message.messageIdHeader)
            for index in merged.indices where !matchedProviderIndices.contains(index) {
                let row = merged[index]
                let rowHeader = canonicalProviderMessageID(row.messageId)
                guard row.localMessageID == nil,
                      row.folder == .trash,
                      row.accountID == accountID,
                      messageHeader == nil || rowHeader == nil,
                      Self.matchesUniqueProviderEnvelope(row, message: message) else {
                    continue
                }
                envelopeProvidersByMessage[message.id, default: []].append(index)
                envelopeMessagesByProvider[index, default: []].append(message.id)
            }
        }
        for message in retainedMessages where !matchedMessageIDs.contains(message.id) {
            guard let candidates = envelopeProvidersByMessage[message.id],
                  candidates.count == 1,
                  let providerIndex = candidates.first,
                  envelopeMessagesByProvider[providerIndex]?.count == 1 else {
                continue
            }
            merged[providerIndex] = merged[providerIndex].copy(localMessageID: message.id)
            matchedMessageIDs.insert(message.id)
            matchedProviderIndices.insert(providerIndex)
        }

        for message in retainedMessages where !matchedMessageIDs.contains(message.id) {
            guard let accountID = message.accountID ?? message.account?.id else { continue }
            merged.append(
                WithheldRow(
                    accountID: accountID,
                    folder: .trash,
                    folderPath: "",
                    uid: 0,
                    uidValidity: 0,
                    sender: message.fromName ?? message.fromAddress,
                    senderAddress: message.fromAddress,
                    subject: message.subject,
                    date: message.receivedAt ?? message.sentAt ?? message.ingestedAt,
                    isRead: message.isReadOrFalse,
                    hasAttachments: message.hasAttachments,
                    listId: message.listId,
                    spamScore: nil,
                    authResults: nil,
                    messageId: message.messageIdHeader,
                    localMessageID: message.id
                )
            )
        }
        return merged
    }

    private static func matchesUniqueProviderEnvelope(_ row: WithheldRow, message: Message) -> Bool {
        guard !row.folderPath.isEmpty, row.uid > 0, row.uidValidity > 0,
              normalizedEnvelopeText(row.senderAddress) == normalizedEnvelopeText(message.fromAddress),
              normalizedEnvelopeText(row.subject) == normalizedEnvelopeText(message.subject),
              let providerDate = row.date,
              let messageDate = message.receivedAt ?? message.sentAt else {
            return false
        }
        return abs(providerDate.timeIntervalSince(messageDate)) <= 2
    }

    private static func normalizedEnvelopeText(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func defaultFetchConfig(
        account: Account,
        oauthStore: OAuthTokenStore
    ) async throws -> WithheldFetchConfig? {
        guard let host = account.imapHost,
              let port = account.imapPort,
              let security = account.imapSecurity else { return nil }
        let auth = try await IMAPAuthResolver.resolve(
            account: account,
            oauthStore: oauthStore,
            passwordResolver: MailCredentialBroker.shared
        )
        return WithheldFetchConfig(
            accountID: account.id,
            host: host,
            port: port,
            security: security,
            username: account.imapUsername ?? account.emailAddress,
            pinnedCertSHA256: account.pinnedCertSHA256,
            auth: auth
        )
    }

    /// On-demand body peek for the opened row, decoded to display text off-main.
    /// Read-only (`BODY.PEEK[]`) — never marks the message read.
    func body(for row: WithheldRow) async {
        guard bodyTextByID[row.id] == nil, let config = configsByAccount[row.accountID] else { return }
        bodyLoadingID = row.id
        let svc = service
        let uid = row.uid
        let folder = row.folder
        var text = ""
        do {
            let data = try await svc.fetchBody(uid: uid, expectedUIDValidity: nil, role: folder, config: config)
            // MIMEParser.parse is CPU-/allocation-heavy; Task.detached pushes it off the
            // MainActor. Safe: it's a pure function over Sendable Data → Sendable ParsedEmail
            // and inherits no task-local context (intentional).
            let parsed = try await Task.detached { try MIMEParser.parse(data: data) }.value
            // Junk is overwhelmingly HTML-only; `summarizableBodyText` returns the
            // plain-text body when present and otherwise renders `htmlBody` to plain
            // text via OhiaIngest's pure-Swift tag stripper (no NSAttributedString /
            // WebKit), which is safe inside this off-main `Task.detached`.
            text = parsed.summarizableBodyText ?? ""
        } catch {
            text = ""
        }
        bodyTextByID[row.id] = text
        if bodyLoadingID == row.id { bodyLoadingID = nil }
    }

    /// Extend the in-memory linear search with a server-side header search for
    /// messages older than the loaded window, merging new rows in by id.
    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        let roles: [WithheldFolderRole]
        switch scope {
        case .all: roles = [.junk, .trash]
        case .junk: roles = [.junk]
        case .trash: roles = [.trash]
        }
        let svc = service
        let configs = Array(configsByAccount.values)
        var found: [WithheldRow] = []
        await withTaskGroup(of: [WithheldRow].self) { group in
            for config in configs {
                for role in roles {
                    let cfg = config
                    group.addTask { (try? await svc.searchOlder(role: role, config: cfg, query: q)) ?? [] }
                }
            }
            for await rows in group { found.append(contentsOf: rows) }
        }
        let existing = Set(rows.map(\.id))
        rows.append(contentsOf: found.filter { !existing.contains($0.id) })
    }

    // MARK: - Promotion (Not Junk / Restore)

    /// Promote a withheld message into the corpus + Inbox: the coordinator fetches
    /// the raw bytes (re-resolving a stale UID by Message-ID), ingests it as
    /// historical mail (no arrival moment), then enqueues the server move. On
    /// success the row leaves the drawer; on failure the message is surfaced inline.
    ///
    /// The corpus-write dependencies (`ingester`/`moveQueue`) are injected by the
    /// view because they need the app's `ModelContext` + `CanonicalStore`; the
    /// read-only IMAP fetch reuses this model's own `WithheldFolderService` and the
    /// `WithheldFetchConfig` resolved during `load`.
    func promote(
        _ row: WithheldRow,
        ingester: any WithheldPromotionIngesting,
        moveQueue: any WithheldPromotionMoveQueueing
    ) async {
        guard promotingID == nil else { return }   // one promotion at a time
        guard let config = configsByAccount[row.accountID] else {
            promoteErrors[row.id] = "No live connection for this account. Reopen Withheld and try again."
            return
        }
        promoteErrors[row.id] = nil
        promotingID = row.id
        defer { if promotingID == row.id { promotingID = nil } }

        let coordinator = WithheldPromotionCoordinator(
            bodySource: promotionBodySource,
            ingester: ingester,
            moveQueue: moveQueue
        )
        let request = WithheldPromotionRequest(
            accountID: row.accountID,
            role: row.folder,
            folderPath: row.folderPath,
            uid: row.uid,
            uidValidity: row.uidValidity,
            messageID: row.messageId,
            feedbackEvidence: row.folder == .junk
                ? MailboxSpamFeedbackEvidence(
                    accountID: row.accountID,
                    senderAddress: row.senderAddress,
                    subject: row.subject,
                    listId: row.listId
                )
                : nil,
            feedbackProviderSpamScore: row.spamScore
        )
        do {
            _ = try await coordinator.promote(request, config: config)
            appendRestoreSpamFeedbackSignal(for: row)
            rows.removeAll { $0.id == row.id }
            promoteErrors[row.id] = nil
            if selectedID == row.id { selectedID = nil }
            selectedRowIDs.remove(row.id)
            if selectionAnchorID == row.id {
                selectionAnchorID = visibleRows.last(where: { selectedRowIDs.contains($0.id) })?.id
            }
            if selectedRowIDs.isEmpty { selectionAnchorID = nil }
        } catch {
            promoteErrors[row.id] = Self.promoteErrorMessage(error)
        }
    }

    private func appendRestoreSpamFeedbackSignal(for row: WithheldRow) {
        guard row.folder == .junk else { return }
        let evidence = MailboxSpamFeedbackEvidence(
            accountID: row.accountID,
            senderAddress: row.senderAddress,
            subject: row.subject,
            listId: row.listId
        )
        guard let signal = MailboxSpamFeedbackSignal(
            kind: .ham,
            accountID: row.accountID,
            evidence: evidence
        ) else {
            return
        }
        mailboxSpamFeedbackSignals.insert(signal, at: 0)
    }

    /// Human-facing, non-anthropomorphic copy for promotion failures.
    private static func promoteErrorMessage(_ error: Error) -> String {
        if let promotion = error as? WithheldPromotionError {
            switch promotion {
            case .staleUIDUnresolved:
                return "This message moved on the server and could not be located. Reopen Withheld and try again."
            case .ingestReturnedNoMessage, .ingestUnexpectedlySkipped:
                return "Could not bring this message into Ohia. Try again."
            }
        }
        return error.localizedDescription
    }

    private func pruneSelectionToCurrentRows() {
        let existing = Set(rows.map(\.id))
        selectedRowIDs = selectedRowIDs.intersection(existing)
        if let selectedID, !existing.contains(selectedID) {
            self.selectedID = nil
        }
        if let selectionAnchorID, !existing.contains(selectionAnchorID) {
            self.selectionAnchorID = visibleRows.last(where: { selectedRowIDs.contains($0.id) })?.id
        }
        if selectedRowIDs.isEmpty {
            selectionAnchorID = nil
        }
    }
}

private struct WithheldLoadRequest {
    let accounts: [Account]
    let oauthStore: OAuthTokenStore
    let modelContext: ModelContext?
    let now: Date
}

private enum WithheldLoadOutcome: Sendable {
    case rows([WithheldRow])
    case cancelled
    case failure(UUID, String)
}

private extension WithheldRow {
    func copy(isRead: Bool) -> WithheldRow {
        WithheldRow(
            accountID: accountID,
            folder: folder,
            folderPath: folderPath,
            uid: uid,
            uidValidity: uidValidity,
            sender: sender,
            senderAddress: senderAddress,
            subject: subject,
            date: date,
            isRead: isRead,
            hasAttachments: hasAttachments,
            listId: listId,
            spamScore: spamScore,
            authResults: authResults,
            messageId: messageId,
            localMessageID: localMessageID
        )
    }

    func copy(localMessageID: UUID) -> WithheldRow {
        WithheldRow(
            accountID: accountID,
            folder: folder,
            folderPath: folderPath,
            uid: uid,
            uidValidity: uidValidity,
            sender: sender,
            senderAddress: senderAddress,
            subject: subject,
            date: date,
            isRead: isRead,
            hasAttachments: hasAttachments,
            listId: listId,
            spamScore: spamScore,
            authResults: authResults,
            messageId: messageId,
            localMessageID: localMessageID
        )
    }
}
