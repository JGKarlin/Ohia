// Ohia/Settings/AccountsListView.swift
// Settings → Accounts tab. Per-row live status, needs-attention section,
// "Add another account" button.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaMail
import OhiaML
import OhiaScheduler

struct AccountsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(IMAPSessionManager.self) private var sessionManager: IMAPSessionManager?
    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(\.workerFleetSupervisor) private var workerSupervisor
    @Environment(PipelinePauseState.self) private var pipelinePauseState
    @Query private var accounts: [Account]
    @AppStorage("hasCompletedOnboarding", store: OhiaSharedDefaults.store)
    private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedFirstIngestion", store: OhiaSharedDefaults.store)
    private var hasCompletedFirstIngestion = false
    @AppStorage(
        OnboardingPipelineGate.hasReachedWitnessPanelKey,
        store: OhiaSharedDefaults.store
    )
    private var hasReachedOnboardingWitnessPanel = false
    @AppStorage(
        OnboardingPipelineGate.hasRequestedModelPreparationKey,
        store: OhiaSharedDefaults.store
    )
    private var hasRequestedOnboardingModelPreparation = false

    @State private var showAddAccount = false
    @State private var credentialSheet: AccountCredentialSheet?
    @State private var showConfirmDisconnect: Account?
    @State private var editingIdentity: IdentitySheet.Mode?
    @State private var disconnecting = false
    @State private var pendingDisconnectID: UUID?
    @State private var disconnectError: String?

    private var attentionAccounts: [Account] {
        accounts.filter { AccountHealthPresentation.make(for: $0).requiresAttention }
    }

    private var readyAccounts: [Account] {
        accounts.filter { AccountHealthPresentation.make(for: $0).requiresAttention == false }
    }

    var body: some View {
        content
            .sheet(item: $credentialSheet) { sheet in
                switch sheet {
                case .outgoing(let account, let requiresFreshOAuth):
                    SetUpOutgoingSheet(
                        account: account,
                        requiresFreshOAuth: requiresFreshOAuth
                    )
                case .imap(let account):
                    SetUpIMAPSheet(account: account)
                }
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountSheet()
            }
            .sheet(item: $editingIdentity) { mode in
                IdentitySheet(mode: mode)
            }
            .alert(
                "Disconnect \(showConfirmDisconnect?.emailAddress ?? "")?",
                isPresented: Binding(
                    get: { showConfirmDisconnect != nil },
                    set: { if !$0 { showConfirmDisconnect = nil } }
                ),
                presenting: showConfirmDisconnect
            ) { account in
                Button("Disconnect", role: .destructive) {
                    disconnect(account)
                    showConfirmDisconnect = nil
                }
                Button("Cancel", role: .cancel) {
                    showConfirmDisconnect = nil
                }
            } message: { _ in
                Text("Removes this account and its emails, attachments, memories, training examples, Composer drafts, and queued sends from Ohia. Previously learned model personalization is retained. Your source mailbox is unchanged.")
            }
            .task {
                do {
                    pendingDisconnectID = try AccountDisconnectionRequest.load(in: OhiaStorageRoot.resolve())?.accountID
                    if pendingDisconnectID != nil {
                        disconnectError = "Account cleanup is pending. Background work is paused until cleanup finishes."
                    }
                } catch { disconnectError = error.localizedDescription }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaAddIdentityFromMenu)) { _ in
                guard hasCompletedOnboarding else { return }
                // No per-row selection model exists yet; prefer a ready account,
                // then an account needing attention. No-op if there are none.
                if let target = readyAccounts.first ?? attentionAccounts.first ?? accounts.first {
                    editingIdentity = .create(target)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if hasCompletedOnboarding {
            accountsManagementContent
        } else {
            onboardingLockedContent
        }
    }

    private var accountsManagementContent: some View {
        // ScrollView owns the overflow: expanding a row's History (the
        // ingestion-window slider) grows past the fixed 960×620 Settings
        // window — without it the VStack pushed content off the top.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if disconnecting {
                    ProgressView("Disconnecting account")
                } else if let disconnectError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(disconnectError)
                        if let pendingDisconnectID {
                            Button("Retry cleanup") { disconnect(accountID: pendingDisconnectID) }
                                .buttonStyle(.emblem)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Accounts").font(.title2)
                    if !attentionAccounts.isEmpty {
                        AccountAttentionSummary(count: attentionAccounts.count)
                    }
                    Spacer()
                }

                if !attentionAccounts.isEmpty {
                    accountSection(
                        title: "Needs attention",
                        accounts: attentionAccounts
                    )
                }

                if !readyAccounts.isEmpty {
                    accountSection(
                        title: attentionAccounts.isEmpty ? "Connected accounts" : "Ready",
                        accounts: readyAccounts
                    )
                }

                if accounts.isEmpty {
                    GroupBox {
                        Text("No accounts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }

                Button("+ Add another account") {
                    showAddAccount = true
                }
                .buttonStyle(.emblem)
                .disabled(disconnecting || pendingDisconnectID != nil)

                Spacer()
            }
            .padding()
        }
    }

    private var onboardingLockedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Accounts").font(.title2)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Finish onboarding to manage accounts", systemImage: "lock")
                        .font(.headline)
                    Text("Aliases, identities, credentials, and additional accounts unlock after the selected account finishes setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func accountSection(title: String, accounts sectionAccounts: [Account]) -> some View {
        Text(title).font(.headline)
        // Each account is its own card so there is real background space
        // between accounts, not a hairline divider inside one shared box.
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sectionAccounts, id: \.id) { account in
                let health = AccountHealthPresentation.make(for: account)
                GroupBox {
                    AccountRowView(
                        account: account,
                        health: health,
                        onCredentialAction: { action in
                            presentCredentialSheet(action, for: account)
                        },
                        onDisableLiveSync: { disableLiveSync(account) },
                        onDisconnect: { showConfirmDisconnect = account },
                        onRemovePin: { removePin(account) },
                        onEditIdentity: { mode in editingIdentity = mode }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(disconnecting || pendingDisconnectID != nil)
            }
        }
    }

    // MARK: - Actions

    private func presentCredentialSheet(
        _ action: AccountHealthPresentation.CredentialAction,
        for account: Account
    ) {
        guard hasCompletedOnboarding else { return }
        switch action {
        case .outgoing(let requiresFreshOAuth):
            credentialSheet = .outgoing(
                account: account,
                requiresFreshOAuth: requiresFreshOAuth
            )
        case .imap:
            credentialSheet = .imap(account: account)
        }
    }

    private func disableLiveSync(_ account: Account) {
        guard hasCompletedOnboarding else { return }
        Task {
            await sessionManager?.stopSession(for: account.id)
            await MainActor.run {
                account.imapHost = nil
                account.imapPort = nil
                account.imapKeychainRef = nil
                try? modelContext.save()
            }
        }
    }

    private func disconnect(_ account: Account) {
        guard hasCompletedOnboarding else { return }
        disconnect(accountID: account.id)
    }

    private func disconnect(accountID: UUID) {
        guard !disconnecting else { return }
        disconnecting = true
        disconnectError = nil
        Task {
            defer { disconnecting = false }
            do {
                guard let appServices, let workerSupervisor else { throw AccountsListError.missingAppServices }
                let layout = try OhiaStorageRoot.resolve()
                try AccountDisconnectionRequest.begin(accountID: accountID, in: layout, resumePipeline: !pipelinePauseState.isPaused)
                let shouldResume = try AccountDisconnectionRequest.load(in: layout)?.resumePipeline == true
                pendingDisconnectID = accountID
                if let account = accounts.first(where: { $0.id == accountID }) { account.status = .paused }
                try modelContext.save()
                NotificationCenter.default.post(name: .ohiaPausePipeline, object: nil, userInfo: ["skipWorkerStop": true])
                appServices.trainingEngine?.cancel()
                guard await workerSupervisor.stopAndWait() else {
                    throw AccountsListError.workersStillRunning
                }
                await sessionManager?.stopAllSessions()
                await appServices.translationService.clearCache()
                await appServices.contextOrientationService.clearCache()
                await appServices.projectSummaryService.clearCache()
                await appServices.deadlineSummaryService.clearCache()
                await appServices.attachmentSummaryService.clearCache()

                let deletedIDs = try AccountContentDeletion(
                    context: modelContext, layout: layout, vectorStore: appServices.vectorStore,
                    canonicalStore: appServices.canonicalStore
                ).remove(accountID: accountID) { service, reference in
                    try KeychainHelpers.delete(service: service, account: reference)
                }
                pendingDisconnectID = nil
                appServices.jobCompletionBroadcaster.yield(JobCompletionEvent(
                    type: .imapDeletionWatch, payload: nil, completedAt: .now,
                    messageMutations: [PipelineMessageMutation(messageIDs: deletedIDs, facets: [.visibility])]
                ))
                let remaining = try modelContext.fetchCount(FetchDescriptor<Account>())
                if remaining == 0 {
                    hasCompletedOnboarding = false
                    hasCompletedFirstIngestion = false
                    hasReachedOnboardingWitnessPanel = false
                    hasRequestedOnboardingModelPreparation = false
                } else if shouldResume {
                    NotificationCenter.default.post(name: .ohiaResumePipeline, object: nil)
                }
            } catch {
                disconnectError = "Account cleanup did not finish: \(error.localizedDescription)"
                if pendingDisconnectID != nil {
                    disconnectError? += " Background work remains paused; retry cleanup to finish."
                }
            }
        }
    }

    private func removePin(_ account: Account) {
        guard hasCompletedOnboarding else { return }
        account.pinnedCertSHA256 = nil
        try? modelContext.save()
    }
}

private enum AccountCredentialSheet: Identifiable {
    case outgoing(account: Account, requiresFreshOAuth: Bool)
    case imap(account: Account)

    var id: String {
        switch self {
        case .outgoing(let account, let requiresFreshOAuth):
            return "outgoing-\(account.id.uuidString)-\(requiresFreshOAuth)"
        case .imap(let account):
            return "imap-\(account.id.uuidString)"
        }
    }
}

private enum AccountsListError: LocalizedError {
    case missingAppServices
    case workersStillRunning

    var errorDescription: String? {
        switch self {
        case .missingAppServices:
            return "App services unavailable for account artifact cleanup."
        case .workersStillRunning:
            return "Background workers have not stopped. No account content was deleted."
        }
    }
}

private struct AccountAttentionSummary: View {
    let count: Int

    var body: some View {
        Label(summaryText, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(OhiaColors.ohiaRed)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(OhiaColors.ohiaRed.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(OhiaColors.ohiaRed.opacity(0.25), lineWidth: 1)
            )
    }

    private var summaryText: String {
        count == 1 ? "1 account needs attention" : "\(count) accounts need attention"
    }
}
