import SwiftUI
import SwiftData
import OhiaCore
import OhiaScheduler

struct SetUpOutgoingSheet: View {
    let account: Account
    let requiresFreshOAuth: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(IMAPSessionManager.self) private var sessionManager: IMAPSessionManager?
    @Environment(\.workerFleetSupervisor) private var workerSupervisor

    @State private var formState: SMTPConfigFormState
    @State private var didHydrate = false

    init(account: Account, requiresFreshOAuth: Bool) {
        self.account = account
        self.requiresFreshOAuth = requiresFreshOAuth
        _formState = State(initialValue: SMTPConfigFormState(emailAddress: account.emailAddress))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                SMTPConfigFormView(
                    state: formState,
                    account: account,
                    requiresFreshOAuth: requiresFreshOAuth,
                    onSave: { _ in finishSave() }
                )
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 560)
        .task(id: account.id) {
            guard !didHydrate else { return }
            didHydrate = true
            formState.hydrate(from: account)
            formState.applyProviderDefaults()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerTitle)
                .font(.headline)
            Text(headerSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerTitle: String {
        if account.needsReauth && account.needsImapReauth {
            return "Reauthorize account"
        }
        if requiresFreshOAuth || account.needsReauth {
            return "Sign in again"
        }
        if account.imapHost == nil || account.imapKeychainRef == nil {
            return "Configure mail access"
        }
        return "Connect this account"
    }

    private var headerSubtitle: String {
        if account.needsReauth && account.needsImapReauth {
            return "Sign in again to restore sending and live sync for \(account.emailAddress)."
        }
        if requiresFreshOAuth || account.needsReauth {
            return "Approve access again for \(account.emailAddress)."
        }
        if account.imapHost == nil || account.imapKeychainRef == nil {
            return "Approve access or enter an app-specific password for \(account.emailAddress)."
        }
        return "Use the app-specific password or mail password your provider gives you for \(account.emailAddress)."
    }

    private func finishSave() {
        Task {
            if let sessionManager, account.imapHost != nil, account.imapKeychainRef != nil {
                await sessionManager.reset(account: account)
            } else {
                IMAPSessionManager.clearIMAPFailureCooldowns(accountID: account.id, context: modelContext)
                try? modelContext.save()
            }
            wakeRetrievalWorkerForLiveSync()
            await MainActor.run {
                dismiss()
            }
        }
    }

    private func wakeRetrievalWorkerForLiveSync() {
        guard account.imapHost != nil, account.imapKeychainRef != nil else { return }
        _ = workerSupervisor?.start(roles: [.bge])
    }
}
