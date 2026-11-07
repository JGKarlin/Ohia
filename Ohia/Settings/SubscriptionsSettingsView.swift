// Ohia/Settings/SubscriptionsSettingsView.swift
// The subscriptions ledger: one row per mailing list / listserv / group an
// account receives, aggregated at ingestion from RFC 2919 List-Id headers.
// Every element is operational: identity, volume, cadence, recency,
// read-rate, subscription state, one-click unsubscribe, and a jump into
// the Constellation scoped to the list's actual messages.

import SwiftUI
import SwiftData
import AppKit
import OhiaCore
import OhiaIngest
import OhiaMail
import OhiaML
import OhiaScheduler

struct SubscriptionsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var appServices: AppServices?

    @State private var lists: [MailingList] = []
    /// (read, total) message counts per account/list scope, computed alongside `lists`.
    @State private var readCounts: [String: (read: Int, total: Int)] = [:]
    @State private var ignoreRulesByListScope: [String: [MailingListIgnoreRule]] = [:]
    @State private var ignoreRulesByID: [UUID: MailingListIgnoreRule] = [:]
    @State private var ignoredMessages: [MailingListIgnoredMessage] = []
    @State private var ignoredMessageTotalCount = 0
    @State private var ignoredMessageLimit = 100
    @State private var accountsByID: [UUID: Account] = [:]
    @State private var actionError: String?
    /// Lists with an unsubscribe currently executing (disables the button).
    @State private var unsubscribing: Set<UUID> = []
    @State private var expandedIgnoredRuleLists: Set<UUID> = []
    @State private var evidenceRule: MailingListIgnoreRule?
    @State private var restoringIgnoredMessageIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Mailing Lists & Subscriptions")
                    .font(OhiaTypography.cardTitle)
                    .foregroundStyle(OhiaColors.textPrimary)
                Spacer()
                Text(summaryLine)
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textTertiary)
            }

            if let actionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(OhiaColors.frameUrgencyHigh)
                    Text(actionError)
                        .font(OhiaTypography.cardBody)
                        .foregroundStyle(OhiaColors.textPrimary)
                    Spacer()
                    Button("Dismiss") { self.actionError = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(OhiaColors.textDim)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(OhiaColors.settingsCard))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if lists.isEmpty {
                        VStack(spacing: 6) {
                            Text("No mailing lists detected")
                                .font(OhiaTypography.cardTitle)
                                .foregroundStyle(OhiaColors.textSecondary)
                            Text("Lists identify themselves with a List-Id header at ingestion. Mail ingested before list tracking existed needs a re-ingest to appear here.")
                                .font(OhiaTypography.cardBody)
                                .foregroundStyle(OhiaColors.textDim)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 440)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(lists) { list in
                            listRow(list)
                        }
                    }

                    ignoredMessagesSection
                }
            }
        }
        // Header on the sky, each list row a floating black card below —
        // matching the General/Sources idiom; no full-pane slab.
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .onAppear { reload() }
        .sheet(item: $evidenceRule) { rule in
            MailingListIgnoreRuleEvidenceSheet(rule: rule)
                .frame(minWidth: 560, minHeight: 420)
        }
    }

    private var summaryLine: String {
        let active = lists.filter { $0.resolvedStatus() == MailingListStatus.subscribed }.count
        let ignored = ignoreRulesByID.values.filter(\.isActive).count
        return "\(lists.count) lists · \(active) active · \(ignored) ignored labels"
    }

    private func listRow(_ list: MailingList) -> some View {
        let status = list.resolvedStatus()
        let scopeKey = ignoreRuleScopeKey(accountID: list.accountID, listId: list.listId)
        let counts = readCounts[scopeKey]
        let rules = ignoreRulesByListScope[scopeKey] ?? []
        let isExpanded = expandedIgnoredRuleLists.contains(list.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(listLabel(list))
                    .font(OhiaTypography.cardTitle)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !rules.isEmpty {
                    ignoredRulesBadge(count: rules.count)
                    Button {
                        toggleIgnoredRules(for: list)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(OhiaColors.chipActiveForeground)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide ignored labels" : "Show ignored labels")
                }
                statusLabel(status)
            }
            HStack(spacing: 10) {
                Text("\(list.messageCount) messages")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textSecondary)
                Text(cadenceLabel(list))
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textSecondary)
                if let counts, counts.total > 0 {
                    Text("\(Int((Double(counts.read) / Double(counts.total) * 100).rounded()))% read")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
                Text("last \(list.lastReceivedAt.formatted(.relative(presentation: .named)))")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textTertiary)

                Spacer()

                Button("Filter Select") {
                    showInConstellation(list)
                }
                .buttonStyle(.emblem)
                .font(OhiaTypography.cardSignal)

                if status == MailingListStatus.subscribed {
                    Button(unsubscribeButtonTitle(list)) {
                        unsubscribe(list)
                    }
                    .buttonStyle(EmblemButtonStyle(tint: OhiaColors.ohiaRed))
                    .font(OhiaTypography.cardSignal)
                    .disabled(unsubscribing.contains(list.id))
                } else if status == MailingListStatus.unsubscribePending {
                    // The list may keep mailing after a request (broken
                    // endpoint, ignored mailto) — pending must never be a
                    // dead end, so retry stays available.
                    Button("Retry Unsubscribe") {
                        unsubscribe(list)
                    }
                    .buttonStyle(.emblem)
                    .font(OhiaTypography.cardSignal)
                    .disabled(unsubscribing.contains(list.id))
                }
            }
            if !rules.isEmpty, isExpanded {
                Divider()
                    .overlay(OhiaColors.glassBorder)
                    .padding(.vertical, 4)
                MailingListIgnoredRulesSection(
                    rules: rules,
                    onBroaden: broadenRule,
                    onNarrow: narrowRule,
                    onRevoke: revokeRule,
                    onDelete: deleteRule,
                    onEvidence: { evidenceRule = $0 }
                )
            }
        }
        .padding(12)
        .background(OhiaColors.settingsCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        )
    }

    private func statusLabel(_ status: String) -> some View {
        let (text, color): (String, Color) = switch status {
        case MailingListStatus.unsubscribePending:
            ("unsubscribe pending", OhiaColors.accentTeal)
        case MailingListStatus.unsubscribed:
            ("unsubscribed", OhiaColors.textTertiary)
        default:
            ("subscribed", OhiaColors.statusReady)
        }
        return Text(text)
            .font(OhiaTypography.cardSignal)
            .foregroundStyle(color)
    }

    private func ignoredRulesBadge(count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10, weight: .semibold))
            Text("\(count) ignored")
                .font(OhiaTypography.cardSignal)
        }
        .foregroundStyle(OhiaColors.chipActiveForeground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(OhiaColors.chipActiveBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(OhiaColors.chipActiveBorder, lineWidth: 1)
        )
    }

    private func toggleIgnoredRules(for list: MailingList) {
        if expandedIgnoredRuleLists.contains(list.id) {
            expandedIgnoredRuleLists.remove(list.id)
        } else {
            expandedIgnoredRuleLists.insert(list.id)
        }
    }

    private func broadenRule(_ rule: MailingListIgnoreRule) {
        do {
            try MailingListIgnoreRuleService(context: modelContext, jobQueue: JobQueue())
                .broaden(ruleID: rule.id)
            reload()
        } catch {
            actionError = "Could not broaden \(rule.displayLabel): \(error.localizedDescription)"
        }
    }

    private func narrowRule(_ rule: MailingListIgnoreRule) {
        do {
            try MailingListIgnoreRuleService(context: modelContext, jobQueue: JobQueue())
                .narrow(ruleID: rule.id)
            reload()
        } catch {
            actionError = "Could not narrow \(rule.displayLabel): \(error.localizedDescription)"
        }
    }

    private func deleteRule(_ rule: MailingListIgnoreRule) {
        do {
            try MailingListIgnoreRuleService(context: modelContext, jobQueue: JobQueue())
                .deleteRuleAndHistory(ruleID: rule.id)
            reload()
        } catch {
            actionError = "Could not delete \(rule.displayLabel): \(error.localizedDescription)"
        }
    }

    private func revokeRule(_ rule: MailingListIgnoreRule) {
        do {
            try MailingListIgnoreRuleService(context: modelContext, jobQueue: JobQueue())
                .revoke(ruleID: rule.id)
            reload()
        } catch {
            actionError = "Could not revoke \(rule.displayLabel): \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var ignoredMessagesSection: some View {
        Divider()
            .overlay(OhiaColors.glassBorder)
            .padding(.vertical, 6)
        HStack(spacing: 8) {
            Label("Ignored Emails", systemImage: "eye.slash.circle.fill")
                .font(OhiaTypography.cardTitle)
                .foregroundStyle(OhiaColors.textPrimary)
            Spacer()
            Text(ignoredMessageCountLabel)
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
        }
        Text("Messages moved by an ignore rule remain visible here after their local mail rows leave Ohia.")
            .font(OhiaTypography.cardBody)
            .foregroundStyle(OhiaColors.textDim)

        if ignoredMessages.isEmpty {
            Text("No ignored emails")
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            ForEach(ignoredMessages) { history in
                MailingListIgnoredMessageRow(
                    history: history,
                    ruleLabel: ignoreRulesByID[history.ruleID]?.displayLabel,
                    isRestoring: restoringIgnoredMessageIDs.contains(history.id),
                    canRestore: history.isRemoteTrashCompleted
                        && !history.isRestored
                        && history.messageIdHeader?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        && appServices != nil,
                    onRestore: { restoreIgnoredMessage(history, refiningRule: false) },
                    onRestoreAndExclude: { restoreIgnoredMessage(history, refiningRule: true) }
                )
            }
            if ignoredMessages.count < ignoredMessageTotalCount {
                Button("Show Older") {
                    ignoredMessageLimit += 100
                    reload()
                }
                .buttonStyle(.emblem)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            }
        }
    }

    private var ignoredMessageCountLabel: String {
        if ignoredMessages.count < ignoredMessageTotalCount {
            return "\(ignoredMessages.count) of \(ignoredMessageTotalCount)"
        }
        return "\(ignoredMessageTotalCount) tracked"
    }

    private func restoreIgnoredMessage(
        _ history: MailingListIgnoredMessage,
        refiningRule: Bool
    ) {
        guard !restoringIgnoredMessageIDs.contains(history.id),
              let appServices,
              let account = accountsByID[history.accountID] else {
            return
        }
        restoringIgnoredMessageIDs.insert(history.id)
        Task { @MainActor in
            defer { restoringIgnoredMessageIDs.remove(history.id) }
            do {
                guard let config = try await ignoredMessageFetchConfig(
                    account: account,
                    oauthStore: OAuthTokenStore(allowKeychainInteraction: false)
                ) else {
                    actionError = "The account does not have a complete IMAP configuration."
                    return
                }
                let bodySource = WithheldFolderServiceBodySource(service: WithheldFolderService())
                let orchestrator = IngestionOrchestrator(
                    context: modelContext,
                    canonicalStore: appServices.canonicalStore
                )
                let ingester = OrchestratorPromotionIngester(
                    orchestrator: orchestrator,
                    context: modelContext
                )
                let dispatcher = MailboxMutationDispatcher(
                    context: modelContext,
                    jobQueue: JobQueue(),
                    localDeletionCascade: MessageLocalDeletionCascade(appServices: appServices)
                )
                let service = MailingListIgnoredMessageRestoreService(
                    context: modelContext,
                    bodySource: bodySource,
                    ingester: ingester,
                    moveQueue: DispatcherPromotionMoveQueue(dispatcher: dispatcher)
                )
                try await service.restore(historyID: history.id, config: config)
                if refiningRule {
                    do {
                        try MailingListIgnoreRuleService(context: modelContext, jobQueue: JobQueue())
                            .refineRuleByExcluding(historyID: history.id)
                    } catch {
                        actionError = "The message was restored, but the ignore rule could not be refined: (error.localizedDescription)"
                        reload()
                        return
                    }
                }
                reload()
            } catch {
                actionError = "Could not restore \(history.subject): \(error.localizedDescription)"
                reload()
            }
        }
    }

    private func ignoredMessageFetchConfig(
        account: Account,
        oauthStore: OAuthTokenStore
    ) async throws -> WithheldFetchConfig? {
        guard let host = account.imapHost,
              let port = account.imapPort,
              let security = account.imapSecurity else {
            return nil
        }
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

    private func cadenceLabel(_ list: MailingList) -> String {
        let perWeek = list.messagesPerWeek
        if perWeek >= 1 {
            return String(format: "%.1f/week", perWeek)
        }
        return String(format: "%.1f/month", perWeek * 4.345)
    }

    /// The list's identity for display: its verbatim address when ingestion
    /// captured one (Bcc / group mail), else an address reconstructed from
    /// the canonical `listId`. The sender / team display name is deliberately
    /// never used as the label — a list is identified by its address, not by
    /// whoever last posted to it.
    private func listLabel(_ list: MailingList) -> String {
        if let address = list.listAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !address.isEmpty {
            return address
        }
        return listIdentityLabel(list)
    }

    private func listIdentityLabel(_ list: MailingList) -> String {
        let token = list.listId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return list.lastFromAddress }
        if token.contains("@") { return token }
        if let account = accountsByID[list.accountID],
           let address = accountDomainListAddress(for: token, account: account) {
            return address
        }
        return token
    }

    private func accountDomainListAddress(for token: String, account: Account) -> String? {
        let domains = Set(account.ownedEmailAddresses.compactMap { addressDomain($0) })
        for domain in domains.sorted(by: { $0.count > $1.count }) {
            let suffix = ".\(domain)"
            guard token.hasSuffix(suffix) else { continue }
            let local = String(token.dropLast(suffix.count))
            guard !local.isEmpty, !local.contains(".") else { continue }
            return "\(local)@\(domain)"
        }
        return nil
    }

    private func addressDomain(_ address: String) -> String? {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = normalized.firstIndex(of: "@"),
              normalized.index(after: at) < normalized.endIndex else {
            return nil
        }
        let domain = String(normalized[normalized.index(after: at)...])
        return domain.contains(".") ? domain : nil
    }

    private func unsubscribeButtonTitle(_ list: MailingList) -> String {
        if list.supportsOneClickUnsubscribe { return "Unsubscribe" }
        if list.unsubscribeMailto != nil { return "Unsubscribe by Mail" }
        if list.unsubscribeURL != nil { return "Unsubscribe in Browser" }
        return "Unsubscribe"
    }

    // MARK: - Actions

    private func unsubscribe(_ list: MailingList) {
        guard let account = accountsByID[list.accountID] else {
            actionError = "No account found for \(listLabel(list))."
            return
        }
        guard list.unsubscribeMailto != nil || list.unsubscribeURL != nil else {
            actionError = "\(listLabel(list)) does not advertise an unsubscribe mechanism."
            return
        }
        unsubscribing.insert(list.id)
        let dispatcher = UnsubscribeDispatcher(context: modelContext, jobQueue: JobQueue())
        Task { @MainActor in
            defer { unsubscribing.remove(list.id) }
            do {
                let outcome = try await dispatcher.unsubscribe(from: list, account: account)
                if case .openURL(let url) = outcome {
                    // The parser only stores http(s) targets, but that
                    // invariant lives two packages away — re-check the
                    // scheme at the only place a stored URL reaches the
                    // browser.
                    if let scheme = url.scheme?.lowercased(),
                       scheme == "https" || scheme == "http" {
                        NSWorkspace.shared.open(url)
                    } else {
                        actionError = "\(listLabel(list)) advertises an unsupported unsubscribe link."
                    }
                }
                reload()
            } catch {
                actionError = "Unsubscribe failed for \(listLabel(list)): \(error.localizedDescription)"
            }
        }
    }

    private func showInConstellation(_ list: MailingList) {
        AppCommand.scopeConstellationToList(listId: list.listId, accountID: list.accountID)
        AppCommand.showConstellation()
    }

    // MARK: - Data

    private func reload() {
        lists = ((try? modelContext.fetch(FetchDescriptor<MailingList>())) ?? [])
            .sorted { lhs, rhs in
                if lhs.messagesPerWeek != rhs.messagesPerWeek {
                    return lhs.messagesPerWeek > rhs.messagesPerWeek
                }
                return lhs.lastReceivedAt > rhs.lastReceivedAt
            }

        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })

        let ignoreRules = ((try? modelContext.fetch(FetchDescriptor<MailingListIgnoreRule>())) ?? [])
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedAscending
            }
        ignoreRulesByListScope = Dictionary(grouping: ignoreRules) { rule in
            ignoreRuleScopeKey(accountID: rule.accountID, listId: rule.listId)
        }
        ignoreRulesByID = Dictionary(uniqueKeysWithValues: ignoreRules.map { ($0.id, $0) })
        var ignoredDescriptor = FetchDescriptor<MailingListIgnoredMessage>(
            sortBy: [SortDescriptor(\MailingListIgnoredMessage.ignoredAt, order: .reverse)]
        )
        ignoredDescriptor.fetchLimit = ignoredMessageLimit
        ignoredMessages = (try? modelContext.fetch(ignoredDescriptor)) ?? []
        ignoredMessageTotalCount = (try? modelContext.fetchCount(
            FetchDescriptor<MailingListIgnoredMessage>()
        )) ?? ignoredMessages.count

        // Read-rate per list. Predicate restricts the fetch to list-tagged
        // rows and `propertiesToFetch` keeps row materialization to the two
        // scalars — the ledger must not walk a 100k-message table on the
        // main thread.
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.listId != nil }
        )
        descriptor.propertiesToFetch = [\.accountID, \.listId, \.isRead]
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        var counts: [String: (read: Int, total: Int)] = [:]
        for message in messages {
            guard let accountID = message.accountID,
                  let listId = message.listId else { continue }
            let key = ignoreRuleScopeKey(accountID: accountID, listId: listId)
            var entry = counts[key] ?? (0, 0)
            entry.total += 1
            if message.isRead == true { entry.read += 1 }
            counts[key] = entry
        }
        readCounts = counts
    }

    private func ignoreRuleScopeKey(accountID: UUID, listId: String) -> String {
        "\(accountID.uuidString.lowercased())|\(listId)"
    }
}

private struct MailingListIgnoredRulesSection: View {
    let rules: [MailingListIgnoreRule]
    let onBroaden: (MailingListIgnoreRule) -> Void
    let onNarrow: (MailingListIgnoreRule) -> Void
    let onRevoke: (MailingListIgnoreRule) -> Void
    let onDelete: (MailingListIgnoreRule) -> Void
    let onEvidence: (MailingListIgnoreRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ignored Labels")
                .font(OhiaTypography.cardSignal.weight(.semibold))
                .foregroundStyle(OhiaColors.textSecondary)
            ForEach(rules) { rule in
                MailingListIgnoreRuleRow(
                    rule: rule,
                    onBroaden: { onBroaden(rule) },
                    onNarrow: { onNarrow(rule) },
                    onRevoke: { onRevoke(rule) },
                    onDelete: { onDelete(rule) },
                    onEvidence: { onEvidence(rule) }
                )
            }
        }
    }
}

private struct MailingListIgnoreRuleRow: View {
    let rule: MailingListIgnoreRule
    let onBroaden: () -> Void
    let onNarrow: () -> Void
    let onRevoke: () -> Void
    let onDelete: () -> Void
    let onEvidence: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                labelChip
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.evidenceSubject)
                        .font(OhiaTypography.cardBody)
                        .foregroundStyle(OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        statusPill
                        MailingListIgnoreStrengthMeter(value: rule.matchAggressiveness)
                        Text("\(rule.matchCount) matches")
                        Text(lastMatchedLabel)
                    }
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textSecondary)
                    if let error = rule.lastActionError, !error.isEmpty {
                        Text(error)
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.frameUrgencyHigh)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                actions
            }
        }
        .padding(.vertical, 6)
    }

    private var labelChip: some View {
        Text(rule.displayLabel)
            .font(OhiaTypography.cardSignal.weight(.semibold))
            .foregroundStyle(OhiaColors.chipActiveForeground)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(OhiaColors.chipActiveBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(OhiaColors.chipActiveBorder, lineWidth: 1)
            )
    }

    private var statusPill: some View {
        Label(rule.isActive ? "active" : "disabled", systemImage: rule.isActive ? "checkmark.circle" : "slash.circle")
            .foregroundStyle(rule.isActive ? OhiaColors.statusReady : OhiaColors.textTertiary)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Narrower", action: onNarrow)
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 4))
                .disabled(!rule.isActive)
            Button("Broader", action: onBroaden)
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 4))
                .disabled(!rule.isActive)
            Button("Evidence", action: onEvidence)
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 4))
            if rule.isActive {
                Button("Revoke", action: onRevoke)
                    .buttonStyle(EmblemButtonStyle(tint: OhiaColors.ohiaYellow, horizontalPadding: 8, verticalPadding: 4))
            }
            Button("Delete", role: .destructive, action: onDelete)
                .buttonStyle(EmblemButtonStyle(tint: OhiaColors.ohiaRed, horizontalPadding: 8, verticalPadding: 4))
        }
        .font(OhiaTypography.cardSignal)
    }

    private var lastMatchedLabel: String {
        guard let lastMatchedAt = rule.lastMatchedAt else { return "no matches yet" }
        return "last \(lastMatchedAt.formatted(.relative(presentation: .named)))"
    }
}

private struct MailingListIgnoredMessageRow: View {
    let history: MailingListIgnoredMessage
    let ruleLabel: String?
    let isRestoring: Bool
    let canRestore: Bool
    let onRestore: () -> Void
    let onRestoreAndExclude: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.slash.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaYellow)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(history.subject.isEmpty ? "(no subject)" : history.subject)
                    .font(OhiaTypography.cardBody.weight(.semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let sender = senderLabel {
                        Text(sender)
                    }
                    Text(ruleLabel ?? history.listId)
                    Text(history.ignoredAt.formatted(.relative(presentation: .named)))
                }
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textSecondary)
                statusLine
                if let matchLine {
                    Text(matchLine)
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if history.excludedFromRuleAt != nil {
                    Label("Excluded from future rule matches", systemImage: "hand.raised.circle.fill")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.statusReady)
                }
                if let error = history.lastRemoteError, !error.isEmpty {
                    Text(error)
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.frameUrgencyHigh)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = history.lastRestoreError, !error.isEmpty {
                    Text(error)
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.frameUrgencyHigh)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if canRestore || isRestoring {
                VStack(alignment: .trailing, spacing: 6) {
                    Button(isRestoring ? "Restoring" : "Restore") {
                        onRestore()
                    }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 5))
                    .disabled(isRestoring)
                    if history.excludedFromRuleAt == nil {
                        Button("Restore & Exclude") {
                            onRestoreAndExclude()
                        }
                        .buttonStyle(EmblemButtonStyle(tint: OhiaColors.ohiaYellow, horizontalPadding: 10, verticalPadding: 5))
                        .disabled(isRestoring)
                        .help("Restore this message and teach the rule to keep similar messages")
                    }
                }
            }
        }
        .padding(12)
        .background(OhiaColors.settingsCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        )
    }

    private var senderLabel: String? {
        if let name = history.senderName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let address = history.senderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? nil : address
    }

    private var statusLine: some View {
        let (text, symbol, color): (String, String, Color) = {
            if history.isRestored {
                return ("Restore queued for Inbox", "arrow.uturn.backward.circle.fill", OhiaColors.statusReady)
            }
            if history.wasHiddenLocallyOnly {
                return ("Hidden locally only", "externaldrive.badge.xmark", OhiaColors.textTertiary)
            }
            if history.didRemoteTrashFail {
                return ("Trash move failed", "exclamationmark.triangle.fill", OhiaColors.frameUrgencyHigh)
            }
            if history.restoreRequestedAt != nil {
                return ("Restore requested", "clock.arrow.circlepath", OhiaColors.ohiaYellow)
            }
            if history.isRemoteTrashQueued {
                return ("Trash move queued", "clock.fill", OhiaColors.ohiaYellow)
            }
            if history.isRemoteTrashCompleted {
                return ("Moved to Trash", "trash.circle.fill", OhiaColors.textTertiary)
            }
            return ("Trash move pending", "clock.fill", OhiaColors.textTertiary)
        }()
        return Label(text, systemImage: symbol)
            .font(OhiaTypography.cardSignal)
            .foregroundStyle(color)
    }

    private var matchLine: String? {
        guard let score = history.matchScore else { return nil }
        let signalLabels: [String]
        if let json = history.matchedSignalsJSON,
           let data = json.data(using: .utf8),
           let signals = try? JSONDecoder().decode([String].self, from: data) {
            let mapping = [
                "userEvidence": "selected by you",
                "subjectFamily": "subject family",
                "subjectAnchor": "distinctive subject phrase",
                "primaryTag": "primary tag",
                "bodyEvidence": "body evidence",
                "supportingTag": "supporting tag",
            ]
            signalLabels = signals.compactMap { mapping[$0] }
        } else {
            signalLabels = []
        }
        let reason = signalLabels.isEmpty ? "" : " · \(signalLabels.joined(separator: " · "))"
        return "\(Int((score * 100).rounded()))% match\(reason)"
    }
}

private struct MailingListIgnoreStrengthMeter: View {
    let value: Double

    var body: some View {
        HStack(spacing: 5) {
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .frame(width: 64)
                .tint(OhiaColors.chipActiveForeground)
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textTertiary)
        }
        .help("Rule breadth")
    }
}

private struct MailingListIgnoreRuleEvidenceSheet: View {
    @Environment(\.modelContext) private var modelContext
    let rule: MailingListIgnoreRule

    @State private var sourceMessage: Message?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(rule.displayLabel, systemImage: "eye.slash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                evidenceText("Rule Status", value: rule.isActive ? "active" : "disabled")
                evidenceText("Evidence Subject", value: rule.evidenceSubject)
                if let summary = rule.evidenceSummary, !summary.isEmpty {
                    evidenceText("Evidence Summary", value: summary)
                }
                if let sourceMessage {
                    evidenceText("Current Source Message", value: sourceMessage.subject)
                } else {
                    evidenceText("Current Source Message", value: "not available")
                }
                evidenceChips(title: "Tags", values: rule.semanticTagLabels)
                evidenceChips(title: "Subject Anchors", values: rule.subjectAnchors)
                evidenceChips(title: "Body Anchors", values: rule.bodyAnchors)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(OhiaColors.toolbarBackground)
        .onAppear(perform: loadSourceMessage)
    }

    private func evidenceText(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(OhiaColors.textSecondary)
            Text(value)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func evidenceChips(title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OhiaColors.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(OhiaColors.chipActiveForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(OhiaColors.chipActiveBackground))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OhiaColors.chipActiveBorder, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func loadSourceMessage() {
        guard let messageID = rule.evidenceMessageID else { return }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        sourceMessage = try? modelContext.fetch(descriptor).first
    }
}
