// Ohia/Settings/AccountRowView.swift
// Single row render for Settings → Accounts. Binds to IMAPSessionManager
// for live status, offers Reauthorize / Disable / Disconnect / Remove pin.
// Expands (via DisclosureGroup) to show the account's identities list and
// a "Suggested aliases" section mined from past sent mail.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaMail
import OhiaScheduler

struct AccountRowView: View {
    let account: Account
    let health: AccountHealthPresentation
    let onCredentialAction: (AccountHealthPresentation.CredentialAction) -> Void
    let onDisableLiveSync: () -> Void
    let onDisconnect: () -> Void
    let onRemovePin: () -> Void
    let onEditIdentity: (IdentitySheet.Mode) -> Void

    @Environment(IMAPSessionManager.self) private var sessionManager: IMAPSessionManager?
    @Environment(\.workerFleetSupervisor) private var workerSupervisor
    @Environment(\.modelContext) private var modelContext
    @State private var isIdentityExpanded = false
    @State private var isHistoryExpanded = false
    @State private var isWithheldCleanupExpanded = false
    @State private var showForceResyncConfirmation = false
    @State private var showWithheldCleanupConfirmation = false
    @State private var pendingHistoryPreset: HistoryIngestionPreset?
    @State private var pendingWithheldAutoDeleteSchedule: WithheldAutoDeleteSchedule?
    @State private var historyAnchor: Date = .now

    private var statusText: String {
        guard account.imapHost != nil, account.imapKeychainRef != nil else {
            return "· awaiting configuration"
        }
        guard let sm = sessionManager, let status = sm.statusByAccount[account.id] else {
            if workerSupervisor?.processState(for: .bge) == .running {
                return "· background sync"
            }
            return "· starting"
        }
        switch status {
        case .disconnected:                return "disconnected · will retry on wake / network"
        case .connecting:                  return "connecting"
        case .authing:                     return "authenticating"
        case .selected, .idling:           return "idling"
        case .syncing(let folder):         return "syncing · \(folder)"
        case .reconnecting(let attempt):   return "reconnecting · attempt \(attempt)"
        case .halted(.authFailed):         return "halted · auth failed — reauthorize"
        case .halted(.reauthRequired):     return "halted · reauth required"
        case .halted(.certMismatch(let presented)): return "halted · certificate changed (\(presented.prefix(12))…) — verify"
        case .halted(.tlsError):           return "halted · TLS error"
        case .halted(.protocolViolation):  return "halted · protocol violation"
        }
    }

    private var messageCount: Int {
        max(0, account.messagesIngested)
    }

    private var badges: [String] {
        var bs: [String] = []
        if let provider = MailProviderRegistry.lookup(
            email: account.emailAddress,
            smtpHost: account.smtpHost,
            imapHost: account.imapHost
        ) {
            bs.append(providerName(provider))
        }
        bs.append("IMAP")
        if account.pinnedCertSHA256 != nil { bs.append("pinned cert") }
        return bs
    }

    /// Stable display ordering for the identities list: primary first,
    /// then the rest sorted by createdAt ascending.
    private var orderedIdentities: [Identity] {
        account.identities.sorted { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary && !b.isPrimary }
            return a.createdAt < b.createdAt
        }
    }

    /// Identity pulldown label — pluralizes and shows a count once the
    /// account has aliases beyond its primary address.
    private var identityDisclosureLabel: String {
        let aliasCount = max(0, account.identities.count - 1)
        return aliasCount > 0 ? "Identities (\(account.identities.count))" : "Identity"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            DisclosureGroup(isExpanded: $isIdentityExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    identitiesSection
                    let candidates = SentMailIdentityScanner.candidates(for: account, in: modelContext)
                    if !candidates.isEmpty {
                        suggestedAliasesSection(candidates)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 4)
            } label: {
                Text(identityDisclosureLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)

            DisclosureGroup(isExpanded: $isHistoryExpanded) {
                historyWindowSection
                    .padding(.top, 8)
                    .padding(.leading, 4)
            } label: {
                Text("History")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)

            if account.imapHost != nil {
                DisclosureGroup(isExpanded: $isWithheldCleanupExpanded) {
                    withheldCleanupSection
                        .padding(.top, 8)
                        .padding(.leading, 4)
                } label: {
                    Text("Junk & Trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
        .confirmationDialog(
            "Permanently delete old Junk and Trash for \(account.emailAddress)?",
            isPresented: $showWithheldCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable permanent deletion", role: .destructive) {
                if let pendingWithheldAutoDeleteSchedule {
                    applyWithheldAutoDeleteSchedule(pendingWithheldAutoDeleteSchedule)
                }
                pendingWithheldAutoDeleteSchedule = nil
            }
            Button("Cancel", role: .cancel) {
                pendingWithheldAutoDeleteSchedule = nil
            }
        } message: {
            Text("Ohia will check this account's IMAP Junk and Trash folders once per day. The first cleanup may run as soon as a background worker claims it, and matching messages will be removed from the IMAP server.")
        }
    }

    // MARK: - Header row (existing shape, unchanged)

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.emailAddress).font(.body)
                AccountHealthBadge(presentation: health)
                Text(badges.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                AccountColorMenu(account: account)
            }
            HStack(spacing: 8) {
                Text("\(messageCount) messages")
                Text("·")
                Text(statusText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if health.requiresAttention {
                AccountHealthCallout(presentation: health)
                    .padding(.top, 4)
            }
            HStack(spacing: 12) {
                if let action = health.action {
                    Button(health.actionTitle ?? "Update credentials…") {
                        onCredentialAction(action)
                    }
                    .buttonStyle(.emblem)
                } else if health.requiresAttention == false {
                    Button("Reauthorize") {
                        onCredentialAction(.outgoing(requiresFreshOAuth: true))
                    }
                    .buttonStyle(.emblem)
                }
                Button("Force full re-sync") {
                    showForceResyncConfirmation = true
                }
                .buttonStyle(.emblem)
                .help("Re-checks the server for new or deleted messages we may have missed. May take several minutes for large mailboxes.")
                if account.imapHost != nil {
                    Button("Disable live sync", role: .destructive, action: onDisableLiveSync)
                        .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                }
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                if account.pinnedCertSHA256 != nil {
                    Button("Remove pin", action: onRemovePin)
                        .buttonStyle(.emblem)
                }
            }
            .font(.caption)
            .padding(.top, 4)
            .confirmationDialog(
                "Force a full re-sync of \(account.emailAddress)?",
                isPresented: $showForceResyncConfirmation,
                titleVisibility: .visible
            ) {
                Button("Force re-sync") { forceFullResync() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This re-checks the server for any new or deleted messages we may have missed. It may take several minutes for large mailboxes.")
            }
        }
    }

    /// Resets the per-folder reconciliation timestamps so the background
    /// scheduler immediately re-runs poll, deletion-sync, and Message-ID
    /// reconciliation passes for every folder of this account on its next
    /// tick. Does not blow away `backfillComplete` / fetched cursors —
    /// the user-visible promise is "re-check the server," not "re-download
    /// every message body" (the latter is idempotent under dedup anyway).
    private func forceFullResync() {
        let now = Date()
        for folder in account.imapFolderStates {
            folder.lastPollAt = nil
            folder.lastDeletionSyncAt = nil
            folder.lastMessageIDReconciliationAt = nil
            folder.updatedAt = now
        }
        try? modelContext.save()
    }

    // MARK: - Identities section

    @ViewBuilder
    private var identitiesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if orderedIdentities.isEmpty {
                Text("No identities or aliases yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(orderedIdentities, id: \.id) { ident in
                    identityRow(ident)
                }
            }
            Button {
                onEditIdentity(.create(account))
            } label: {
                Label("Add alias or identity", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)

            HStack(spacing: 6) {
                Image(systemName: "signature")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(
                    account.defaultSignatureSlot.map { "Default signature: \($0.name)" }
                        ?? "No default signature"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Signatures are managed per account in Settings → Signatures.")
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func identityRow(_ ident: Identity) -> some View {
        HStack(spacing: 8) {
            Button {
                guard !ident.isPrimary else { return }
                account.setPrimaryIdentity(ident)
                try? modelContext.save()
            } label: {
                Image(systemName: ident.isPrimary ? "circle.fill" : "circle")
                    .foregroundStyle(ident.isPrimary ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(ident.isPrimary ? "Primary identity" : "Make primary")

            Text(ident.address)
                .font(.caption)

            if let name = ident.displayName, !name.isEmpty {
                Text("(\(name))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let rt = ident.replyTo, !rt.isEmpty {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Reply-To: \(rt)")
            }

            Spacer()

            Button("Edit") { onEditIdentity(.edit(ident)) }
                .buttonStyle(.borderless)
                .font(.caption)

            Button(role: .destructive) {
                removeIdentity(ident)
            } label: {
                Text("Remove")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(ident.isPrimary)
            .help(ident.isPrimary ? "Promote another identity first." : "Remove identity")
        }
        .contextMenu {
            Button("Edit") { onEditIdentity(.edit(ident)) }
            if !ident.isPrimary {
                Button("Make primary") {
                    account.setPrimaryIdentity(ident)
                    try? modelContext.save()
                }
            }
            Button(role: .destructive) {
                removeIdentity(ident)
            } label: {
                Text("Remove")
            }
            .disabled(ident.isPrimary)
        }
    }

    private func removeIdentity(_ ident: Identity) {
        guard !ident.isPrimary else { return }
        modelContext.delete(ident)
        try? modelContext.save()
    }

    // MARK: - History window section

    /// The currently-recorded onboarding preset, if it parses. May be nil
    /// for legacy rows that predate `ingestionWindowPresetRaw`.
    private var currentHistoryPreset: HistoryIngestionPreset? {
        guard let raw = account.ingestionWindowPresetRaw else { return nil }
        return HistoryIngestionPreset(rawValue: raw)
    }

    /// Inferred preset for legacy rows that have a lowerBound but no stored
    /// preset — pick the preset whose lowerBound is closest in time to the
    /// stored bound, or `.allTime` when there's no bound (or the bound is
    /// older than the widest finite preset).
    private var resolvedHistoryPreset: HistoryIngestionPreset {
        if let preset = currentHistoryPreset { return preset }
        guard let actual = account.ingestionLowerBoundAt else { return .allTime }
        let anchor = historyAnchor
        if let widestFinite = HistoryIngestionPreset.fiveYears.lowerBound(anchoredAt: anchor),
           actual < widestFinite {
            return .allTime
        }
        var best: HistoryIngestionPreset = .oneWeek
        var bestDelta: TimeInterval = .infinity
        for preset in HistoryIngestionPreset.allCases {
            guard let bound = preset.lowerBound(anchoredAt: anchor) else { continue }
            let delta = abs(bound.timeIntervalSince(actual))
            if delta < bestDelta {
                bestDelta = delta
                best = preset
            }
        }
        return best
    }

    private var historyWindowDescription: String {
        if let lower = account.ingestionLowerBoundAt {
            return "Currently importing: \(resolvedHistoryPreset.title) (since \(lower.formatted(date: .abbreviated, time: .omitted)))"
        }
        return "Currently importing: \(resolvedHistoryPreset.title)"
    }

    private var pendingIsWider: Bool {
        guard let pending = pendingHistoryPreset else { return false }
        let pendingBound = pending.lowerBound(anchoredAt: historyAnchor)
        return HistoryIngestionWindowPolicy.isWidening(
            oldLowerBound: account.ingestionLowerBoundAt,
            newLowerBound: pendingBound
        )
    }

    @ViewBuilder
    private var historyWindowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(historyWindowDescription)
                .font(.caption)

            HistoryIngestionSlider(
                selection: Binding(
                    get: { pendingHistoryPreset ?? resolvedHistoryPreset },
                    set: { pendingHistoryPreset = $0 }
                ),
                minimumWidening: resolvedHistoryPreset,
                caption: "Expand mail history"
            )
            .padding(.top, 2)

            HistoryIngestionCautionNote(variant: .expansion)

            HStack {
                Spacer()
                Button(
                    "Expand history",
                    systemImage: "clock.arrow.circlepath",
                    action: applyHistoryExpansion
                )
                    .buttonStyle(.emblem)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pendingIsWider)
            }
        }
        .onAppear {
            historyAnchor = .now
            pendingHistoryPreset = resolvedHistoryPreset
        }
    }

    private func applyHistoryExpansion() {
        guard let preset = pendingHistoryPreset, pendingIsWider else { return }
        guard Self.applyHistoryExpansion(
            preset,
            anchoredAt: historyAnchor,
            to: account,
            in: modelContext,
            wakeHistoricalWork: { account in
                sessionManager?.startSession(for: account)
                _ = workerSupervisor?.start(roles: [.bge])
            }
        ) else { return }
        historyAnchor = .now
        pendingHistoryPreset = preset
    }

    @discardableResult
    @MainActor
    static func applyHistoryExpansion(
        _ preset: HistoryIngestionPreset,
        anchoredAt anchor: Date,
        to account: Account,
        in context: ModelContext,
        wakeHistoricalWork: (Account) -> Void
    ) -> Bool {
        let lowerBound = preset.lowerBound(anchoredAt: anchor)
        guard HistoryIngestionWindowPolicy.isWidening(
            oldLowerBound: account.ingestionLowerBoundAt,
            newLowerBound: lowerBound
        ) else { return false }
        account.applyHistoryIngestionWindow(
            lowerBound: lowerBound,
            presetRaw: preset.rawValue,
            now: anchor
        )
        do {
            try context.save()
        } catch {
            print("[Ohia] Expand history save failed: \(String(reflecting: type(of: error)))")
            return false
        }
        wakeHistoricalWork(account)
        return true
    }

    // MARK: - Withheld cleanup section

    private var withheldAutoDeleteScheduleBinding: Binding<WithheldAutoDeleteSchedule> {
        Binding(
            get: { account.withheldAutoDeleteSchedule },
            set: { schedule in
                guard schedule != .off else {
                    pendingWithheldAutoDeleteSchedule = nil
                    applyWithheldAutoDeleteSchedule(schedule)
                    return
                }
                guard account.withheldAutoDeleteSchedule != schedule else { return }
                pendingWithheldAutoDeleteSchedule = schedule
                showWithheldCleanupConfirmation = true
            }
        )
    }

    private var withheldCleanupStatusLine: String {
        guard account.withheldAutoDeleteSchedule != .off else {
            return "Automatic permanent deletion is off for this account."
        }
        if let lastRun = account.withheldAutoDeleteLastRunAt {
            let count = account.withheldAutoDeleteLastDeletedCount ?? 0
            let noun = count == 1 ? "message" : "messages"
            return "Last checked \(lastRun.formatted(date: .abbreviated, time: .shortened)); permanently deleted \(count) \(noun)."
        }
        if account.withheldAutoDeleteLastDeletedCount != nil {
            return "Cleanup is continuing on the next background scheduler pass."
        }
        return "This account will run on the next background scheduler pass."
    }

    @ViewBuilder
    private var withheldCleanupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ohia does not classify incoming mail as junk. It does not ingest messages in your account's Junk or Trash folders. Review and restore them in Withheld.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Permanent delete", selection: withheldAutoDeleteScheduleBinding) {
                ForEach(WithheldAutoDeleteSchedule.allCases) { schedule in
                    Text(schedule.title).tag(schedule)
                }
            }
            .pickerStyle(.menu)
            .disabled(account.imapKeychainRef == nil || account.needsImapReauth)

            Text("Applies to this account's IMAP Junk and Trash folders. Ohia checks once per day and removes messages older than the selected age from the server.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(withheldCleanupStatusLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = account.withheldAutoDeleteLastError,
               account.withheldAutoDeleteSchedule != .off {
                Text("Last cleanup failed: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func applyWithheldAutoDeleteSchedule(_ schedule: WithheldAutoDeleteSchedule) {
        guard account.withheldAutoDeleteSchedule != schedule else { return }
        account.withheldAutoDeleteSchedule = schedule
        account.withheldAutoDeleteLastRunAt = nil
        account.withheldAutoDeleteLastDeletedCount = nil
        account.withheldAutoDeleteLastError = nil
        do {
            try modelContext.save()
        } catch {
            print("[Ohia] Withheld cleanup schedule save failed: \(String(reflecting: type(of: error)))")
            return
        }
        guard schedule != .off else { return }
        enqueueWithheldAutoDeleteIfNeeded()
    }

    private func enqueueWithheldAutoDeleteIfNeeded() {
        guard !hasActiveWithheldAutoDeleteJob() else { return }
        do {
            let payload = try WithheldAutoDeleteWorker.payloadString(accountID: account.id)
            try JobQueue().enqueue(
                type: .withheldAutoDelete,
                priority: WithheldAutoDeleteWorker.priority,
                payload: payload,
                context: modelContext
            )
        } catch {
            print("[Ohia] failed to enqueue withheld cleanup: \(String(reflecting: type(of: error)))")
        }
    }

    private func hasActiveWithheldAutoDeleteJob() -> Bool {
        guard let jobs = try? modelContext.fetch(FetchDescriptor<Job>()) else {
            return false
        }
        return jobs.contains { job in
            guard job.type == .withheldAutoDelete,
                  (job.status == .pending || job.status == .running),
                  let payload = try? WithheldAutoDeleteWorker.decodePayload(from: job) else {
                return false
            }
            return payload.accountID == account.id
        }
    }

    // MARK: - Suggested aliases section

    @ViewBuilder
    private func suggestedAliasesSection(_ candidates: [IdentityCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUGGESTED ALIASES")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(candidates, id: \.address) { cand in
                HStack(spacing: 8) {
                    Text(cand.address)
                        .font(.caption)
                    if let name = cand.displayName, !name.isEmpty {
                        Text("(\(name))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("· \(cand.occurrenceCount) seen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add") { addSuggested(cand) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }

    private func addSuggested(_ cand: IdentityCandidate) {
        let ident = Identity(
            address: cand.address,
            displayName: cand.displayName,
            replyTo: nil,
            isPrimary: false
        )
        ident.account = account
        modelContext.insert(ident)
        do {
            try modelContext.save()
            let repaired = try AliasSentDirectionRepairApplier(modelContext: modelContext).run()
            if repaired > 0 {
                print("[Ohia] Alias sent-direction repair: updated \(repaired) message row(s)")
            }
        } catch {
            print("[Ohia] Suggested alias save failed: \(String(reflecting: type(of: error)))")
        }
    }

    private func providerName(_ provider: MailProvider) -> String {
        let host = provider.imapHost
        if host.contains("gmail") { return "Gmail" }
        if host.contains("icloud") || host.contains("me.com") { return "iCloud" }
        if host.contains("office") || host.contains("outlook") { return "Outlook" }
        if host.contains("fastmail") { return "Fastmail" }
        if host.contains("yahoo") { return "Yahoo" }
        if host.contains("aol") { return "AOL" }
        if host.contains("zoho") { return "Zoho" }
        if host == "127.0.0.1" { return "Proton Bridge" }
        return host.capitalized
    }
}
