// Ohia/Settings/SetUpIMAPSheet.swift
// Resolves a "Needs attention" account: populates imapHost/Port/...
// from MailProviderRegistry, attempts credential reuse (stored SMTP
// password → IMAP), or prompts the user for an app-specific password.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaMail
import OhiaScheduler

struct SetUpIMAPSheet: View {
    let account: Account

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(IMAPSessionManager.self) private var sessionManager: IMAPSessionManager?
    @Environment(\.workerFleetSupervisor) private var workerSupervisor

    @State private var password: String = ""
    @State private var status: String = ""
    @State private var isWorking: Bool = false

    private var provider: MailProvider? {
        MailProviderRegistry.lookup(
            email: account.emailAddress,
            smtpHost: account.smtpHost,
            imapHost: account.imapHost
        )
    }

    /// OAuth only when this build ships the provider's client ID; otherwise
    /// the provider is set up with a password like any other.
    private var usesOAuth: Bool {
        guard let provider, case .oauth2(let id) = provider.imapAuthHint else { return false }
        return OAuthProvider.forID(id).isConfigured
    }

    private var appPasswordInfo: String {
        guard let provider else { return "" }
        switch provider.imapAuthHint {
        case .oauth2(let id) where !usesOAuth:
            return SMTPConfigFormState.passwordSignInNote(for: id)
        case .password:
            if provider.imapHost.contains("icloud") || provider.imapHost.contains("me.com") {
                return "iCloud requires an app-specific password. Generate one at appleid.apple.com → Sign-In and Security → App-Specific Passwords."
            }
            if provider.imapHost.contains("fastmail") {
                return "Fastmail requires an app password. Generate one at fastmail.com → Settings → Password & Security → App Passwords."
            }
            return "Use the app-specific password generated from your provider's security settings."
        case .oauth2:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }

            if let provider {
                Text("Ohia will connect to \(providerDisplay(provider)) (\(provider.imapHost):\(provider.imapPort)).")
                    .font(.body)
                if !appPasswordInfo.isEmpty {
                    Text(appPasswordInfo).font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if usesOAuth {
                        Button("Reauthorize \(providerDisplay(provider))") {
                            Task { await reauthorizeOAuth(provider: provider) }
                        }
                        .font(OhiaTypography.button)
                        .buttonStyle(.emblem)
                        .disabled(isWorking)
                    } else {
                        if account.smtpKeychainRef != nil && account.smtpAuthMethod == .password {
                            Button("Reuse the existing SMTP password") {
                                Task { await tryReuseSMTPPassword() }
                            }
                            .disabled(isWorking)
                        }
                        SecureField("App-specific password", text: $password)
                            .textFieldStyle(.roundedBorder)
                        Button("Save and start IMAP") {
                            Task { await save(newPassword: password) }
                        }
                        .disabled(password.isEmpty || isWorking)
                    }
                }
            } else {
                Text("This provider isn't in the registry. Use Settings → Accounts → Add another account → Connect manually to enter IMAP settings by hand.").font(.body)
            }

            if !status.isEmpty {
                Text(status).font(.caption).monospaced().textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560)
    }

    private var title: String {
        if account.needsImapReauth {
            return "Reauthorize live sync"
        }
        return "Set up live sync"
    }

    @MainActor
    private func reauthorizeOAuth(provider: MailProvider) async {
        isWorking = true
        defer { isWorking = false }
        guard case .oauth2(let providerID) = provider.imapAuthHint else {
            status = "Provider does not use OAuth."
            return
        }
        let oauthProvider: OAuthProvider = providerID == .gmail ? .gmail : .microsoft
        if account.smtpKeychainRef == nil {
            account.smtpKeychainRef = "smtp-oauth-\(account.id.uuidString)"
        }
        do {
            let tokens = try await OAuthCoordinator.signIn(provider: oauthProvider)
            try await OAuthTokenStore().store(tokens: tokens, for: account)
            account.smtpAuthMethod = .oauth2
            account.imapHost = provider.imapHost
            account.imapPort = provider.imapPort
            account.imapSecurity = provider.imapSecurity
            account.imapAuthMethod = .oauth2
            account.imapUsername = account.smtpUsername ?? account.emailAddress
            account.imapKeychainRef = account.smtpKeychainRef
            account.needsReauth = false
            account.needsImapReauth = false
            try modelContext.save()
            if let sessionManager {
                await sessionManager.reset(account: account)
            } else {
                IMAPSessionManager.clearIMAPFailureCooldowns(accountID: account.id, context: modelContext)
                try modelContext.save()
            }
            wakeRetrievalWorkerForLiveSync()
            status = "Saved. Session starting."
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch OAuthCoordinatorError.userCancelled {
            status = ""
        } catch {
            status = "Reauthorization failed: \(error)"
        }
    }

    @MainActor
    private func tryReuseSMTPPassword() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let reference = try SMTPCredentials().keychainReference(for: account)
            let smtpPassword = try await MailCredentialBroker.shared.password(
                kind: .smtpPassword,
                keychainReference: reference
            )
            await save(newPassword: smtpPassword)
        } catch {
            status = "Couldn't read existing SMTP password: \(error)"
        }
    }

    @MainActor
    private func save(newPassword: String) async {
        isWorking = true
        defer { isWorking = false }
        guard let provider else {
            status = "No provider registry entry."
            return
        }
        do {
            try IMAPCredentials().storePassword(newPassword, for: account)
            account.imapHost = provider.imapHost
            account.imapPort = provider.imapPort
            account.imapSecurity = provider.imapSecurity
            account.imapAuthMethod = .password
            account.imapUsername = account.smtpUsername ?? account.emailAddress
            account.needsImapReauth = false
            try modelContext.save()
            if let sessionManager {
                await sessionManager.reset(account: account)
            } else {
                IMAPSessionManager.clearIMAPFailureCooldowns(accountID: account.id, context: modelContext)
                try modelContext.save()
            }
            wakeRetrievalWorkerForLiveSync()
            status = "Saved. Session starting."
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch {
            status = "Save failed: \(error)"
        }
    }

    private func wakeRetrievalWorkerForLiveSync() {
        guard account.imapHost != nil, account.imapKeychainRef != nil else { return }
        _ = workerSupervisor?.start(roles: [.bge])
    }

    private func providerDisplay(_ provider: MailProvider) -> String {
        let h = provider.imapHost
        if h.contains("gmail") { return "Gmail" }
        if h.contains("icloud") || h.contains("me.com") { return "iCloud" }
        if h.contains("fastmail") { return "Fastmail" }
        if h.contains("yahoo") { return "Yahoo" }
        if h.contains("aol") { return "AOL" }
        if h.contains("zoho") { return "Zoho" }
        return h
    }
}
