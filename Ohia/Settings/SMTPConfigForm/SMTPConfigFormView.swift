// Ohia/Settings/SMTPConfigForm/SMTPConfigFormView.swift
import SwiftUI
import SwiftData
import AppKit
import OhiaCore
import OhiaMail

struct SMTPConfigFormPresentation: Equatable {
    enum AuthenticationAction: Equatable {
        case oauth
        case password
    }

    let authenticationActions: [AuthenticationAction]

    init(hasOAuthProvider: Bool, passwordFallbackExpanded: Bool) {
        if hasOAuthProvider {
            authenticationActions = passwordFallbackExpanded
                ? [.oauth, .password]
                : [.oauth]
        } else {
            authenticationActions = [.password]
        }
    }

    static func shouldCancelVerificationOnDisappear(
        isApplicationActive: Bool,
        verificationStage: SMTPConfigFormState.VerificationStage?
    ) -> Bool {
        isApplicationActive && verificationStage != .oauthSignIn
    }
}

struct SMTPConfigFormView: View {
    @Bindable var state: SMTPConfigFormState
    let account: Account
    let requiresFreshOAuth: Bool
    let saveButtonTitle: String
    @Environment(\.modelContext) private var modelContext
    let onSave: (IMAPConnectionConfiguration) -> Void

    @State private var advancedExpanded = false
    @State private var serverDetailsExpanded = false
    @State private var showScopesPopover = false

    init(
        state: SMTPConfigFormState,
        account: Account,
        requiresFreshOAuth: Bool,
        saveButtonTitle: String = "Save",
        onSave: @escaping (IMAPConnectionConfiguration) -> Void
    ) {
        self.state = state
        self.account = account
        self.requiresFreshOAuth = requiresFreshOAuth
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
    }

    var body: some View {
        let verificationFingerprint = state.verificationFingerprint(for: account)
        let presentation = SMTPConfigFormPresentation(
            hasOAuthProvider: state.oauthProviderID != nil,
            passwordFallbackExpanded: advancedExpanded
        )
        return VStack(alignment: .leading, spacing: 16) {
            if let oauthID = state.oauthProviderID {
                providerIdentityCard(oauthID)
                oauthPrimaryButton(oauthID)
                oauthStatusChip
                oauthMicrocopy(oauthID)
                orDivider
                DisclosureGroup(
                    "Use a password instead (advanced)",
                    isExpanded: $advancedExpanded
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        passwordField
                        if oauthID == .gmail {
                            Text("Gmail requires an app password; your regular Google password won't work.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        serverFields
                        if presentation.authenticationActions.contains(.password) {
                            passwordActionRow(saveTitle: "Continue with app password")
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            } else {
                passwordField
                if let note = state.passwordSignInNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                serverFields
                passwordActionRow(saveTitle: saveButtonTitle)
            }
        }
        .onAppear {
            state.applyProviderDefaults()
            if state.host.isEmpty {
                serverDetailsExpanded = true
            }
        }
        .sheet(item: certUntrustedBinding) { info in
            VerifyCertificateSheet(
                info: info,
                hasExistingPin: account.pinnedCertSHA256 != nil,
                onTrust: { trustAndRetest(info: info) },
                onCancel: { state.testStatus = .idle }
            )
        }
        .task(id: verificationFingerprint) {
            state.observeVerificationFingerprint(verificationFingerprint)
        }
        .onChange(of: advancedExpanded) { _, isExpanded in
            state.authMethod = isExpanded ? .password : .oauth2
        }
        .onDisappear {
            if SMTPConfigFormPresentation.shouldCancelVerificationOnDisappear(
                isApplicationActive: NSApp.isActive,
                verificationStage: state.verificationStage
            ) {
                state.cancelVerification()
            }
        }
    }

    // MARK: - Provider identity card

    @ViewBuilder
    private func providerIdentityCard(_ oauthID: MailProvider.OAuthProviderID) -> some View {
        HStack(spacing: 12) {
            ProviderMark(providerID: oauthID, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Account")
                    .font(.caption2)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Text(providerSubtitle(oauthID))
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            Spacer()
            Text("Ready")
                .font(.system(size: 10, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(OhiaColors.accentGreen)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(OhiaColors.accentGreen.opacity(0.10))
                )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OhiaColors.surface(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        )
    }

    private func providerSubtitle(_ oauthID: MailProvider.OAuthProviderID) -> String {
        switch oauthID {
        case .gmail:     return "Google handles sign-in"
        case .microsoft: return "Microsoft handles sign-in"
        }
    }

    // MARK: - OAuth primary button

    @ViewBuilder
    private func oauthPrimaryButton(_ oauthID: MailProvider.OAuthProviderID) -> some View {
        Button {
            state.authMethod = .oauth2
            verifyAndContinue(
                acquireFreshOAuth: requiresFreshOAuth || account.smtpKeychainRef == nil
            )
        } label: {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if state.isVerifying {
                    ProgressView().controlSize(.small)
                } else {
                    ProviderMark(providerID: oauthID, size: 20)
                    Text(oauthButtonLabel(oauthID))
                        .font(.system(size: 14, weight: .medium))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(OhiaColors.buttonBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(OhiaColors.ohiaGreen)
        }
        .buttonStyle(.plain)
        .disabled(state.isVerifying || state.signInStatus == .success)
    }

    // MARK: - OAuth status chip (under the CTA)
    //
    // Renders the combined state of signInStatus + testStatus into a single
    // line under the Continue-with-Google/Microsoft button. Replaces the
    // manual Test button; the combined flow verifies both protocols before
    // the form can advance.

    @ViewBuilder
    private var oauthStatusChip: some View {
        if state.isVerifying {
            successChip(
                text: state.verificationProgressText,
                systemImage: "arrow.triangle.2.circlepath",
                tint: OhiaColors.accentGreen
            )
        } else if case .failure(let message) = state.signInStatus {
            successChip(
                text: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        } else if case .failure(let message) = state.testStatus {
            successChip(
                text: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        } else if state.signInStatus == .success, state.testStatus == .success {
            successChip(
                text: "SMTP and IMAP verified",
                systemImage: "checkmark.circle.fill",
                tint: OhiaColors.accentGreen
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func successChip(
        text: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }

    private func oauthButtonLabel(_ oauthID: MailProvider.OAuthProviderID) -> String {
        switch oauthID {
        case .gmail:     return "Continue with Google"
        case .microsoft: return "Continue with Microsoft"
        }
    }

    // MARK: - Microcopy under the CTA

    @ViewBuilder
    private func oauthMicrocopy(_ oauthID: MailProvider.OAuthProviderID) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(microcopyText(oauthID))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                showScopesPopover.toggle()
            } label: {
                Text("What will Ohia access?")
                    .font(.caption2)
                    .underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showScopesPopover, arrowEdge: .top) {
                scopesPopover(oauthID)
                    .padding(14)
                    .frame(width: 320)
            }
            Spacer(minLength: 0)
        }
    }

    private func microcopyText(_ oauthID: MailProvider.OAuthProviderID) -> String {
        switch oauthID {
        case .gmail:
            return "Use your usual Google sign-in, including passkeys when available."
        case .microsoft:
            return "Use your usual Microsoft sign-in, including passkeys when available."
        }
    }

    @ViewBuilder
    private func scopesPopover(_ oauthID: MailProvider.OAuthProviderID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Ohia can access")
                .font(.headline)
            switch oauthID {
            case .gmail:
                scopeRow(
                    icon: "tray.full",
                    title: "Read and send mail",
                    detail: "Gmail mail access"
                )
                scopeRow(
                    icon: "arrow.clockwise",
                    title: "Stay connected",
                    detail: "offline access"
                )
            case .microsoft:
                scopeRow(
                    icon: "paperplane",
                    title: "Send email",
                    detail: "Microsoft mail access"
                )
                scopeRow(
                    icon: "tray",
                    title: "Read mail",
                    detail: "Microsoft mail access"
                )
                scopeRow(
                    icon: "arrow.clockwise",
                    title: "Stay connected",
                    detail: "offline_access"
                )
            }
            Text("Ohia uses this to read mail on this Mac and send confirmed replies from this account.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func scopeRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - "or" divider

    private var orDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
            Text("or")
                .font(.caption2)
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
        }
    }

    // MARK: - Password + server fields (shared)

    @ViewBuilder
    private var passwordField: some View {
        LabeledContent("Password") {
            SecureField("App-specific password", text: $state.password)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var serverFields: some View {
        DisclosureGroup("Server details", isExpanded: $serverDetailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Host") {
                    TextField("smtp.example.com", text: $state.host)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Username") {
                    TextField("you@example.com", text: $state.username)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("587", text: $state.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
                LabeledContent("Security") {
                    Picker("", selection: $state.security) {
                        Text("STARTTLS (587)").tag(SMTPSecurity.starttls)
                        Text("TLS (465)").tag(SMTPSecurity.tls)
                        if state.allowsUnencryptedSecurity {
                            Text("None").tag(SMTPSecurity.none)
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    // MARK: - Verify + Save row (password path — manual credentials benefit from a pre-Save check)

    @ViewBuilder
    private func passwordActionRow(saveTitle: String) -> some View {
        HStack(spacing: 8) {
            Button("Verify connection") {
                Task { await state.runTest(for: account) }
            }
            .disabled(state.isVerifying || state.testStatus == .running || !hasCredentialsToVerify)

            switch state.testStatus {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().scaleEffect(0.5).controlSize(.small)
            case .success:
                Label("Connection OK", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(OhiaColors.accentGreen)
                    .font(.caption)
            case .failure(let msg):
                Text(msg)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
            case .certUntrusted:
                Label("Verify certificate…", systemImage: "lock.shield")
                    .foregroundStyle(OhiaColors.accentOrange)
                    .font(.caption)
            }

            Spacer()
            saveButton(title: saveTitle)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func saveButton(title: String) -> some View {
        Button(title) {
            state.authMethod = .password
            verifyAndContinue()
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!hasCredentialsToVerify || state.isVerifying)
        .buttonStyle(.emblem)
    }

    private func verifyAndContinue(acquireFreshOAuth: Bool = false) {
        Task {
            await state.verifyAndContinue(
                account: account,
                acquireFreshOAuth: acquireFreshOAuth,
                persistModel: { try modelContext.save() },
                onContinue: { configuration in onSave(configuration) }
            )
        }
    }

    private var hasCredentialsToVerify: Bool {
        !state.host.isEmpty && state.port > 0 && !state.password.isEmpty
    }

    private var certUntrustedBinding: Binding<CertificateInfo?> {
        Binding(
            get: {
                if case .certUntrusted(let info) = state.testStatus { return info }
                return nil
            },
            set: { newValue in
                if newValue == nil, case .certUntrusted = state.testStatus {
                    state.testStatus = .idle
                }
            }
        )
    }

    private func trustAndRetest(info: CertificateInfo) {
        account.pinnedCertSHA256 = info.sha256Fingerprint
        do { try modelContext.save() }
        catch {
            state.testStatus = .failure("Save failed: \(error)")
            return
        }
        state.testStatus = .idle
        Task { await state.runTest(for: account) }
    }
}

// MARK: - ProviderMark

/// Brand-colored square tile rendered in SwiftUI — no bundled asset, stays
/// license-clean. Used in the provider identity card (36pt) and inside the
/// OAuth CTA button (20pt).
struct ProviderMark: View {
    let providerID: MailProvider.OAuthProviderID
    let size: CGFloat

    var body: some View {
        switch providerID {
        case .gmail:
            gmailMark
        case .microsoft:
            microsoftMark
        }
    }

    private var gmailMark: some View {
        Text("G")
            .font(.system(size: size * 0.55, weight: .bold, design: .default))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.26, green: 0.52, blue: 0.96), // Google blue
                        Color(red: 0.20, green: 0.66, blue: 0.33)  // Google green
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
    }

    private var microsoftMark: some View {
        let gap = size * 0.06
        let tile = (size - gap * 3) / 2
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                Rectangle().fill(Color(red: 0.95, green: 0.32, blue: 0.12)).frame(width: tile, height: tile)
                Rectangle().fill(Color(red: 0.48, green: 0.73, blue: 0.22)).frame(width: tile, height: tile)
            }
            HStack(spacing: gap) {
                Rectangle().fill(Color(red: 0.0,  green: 0.62, blue: 0.93)).frame(width: tile, height: tile)
                Rectangle().fill(Color(red: 1.0,  green: 0.73, blue: 0.0 )).frame(width: tile, height: tile)
            }
        }
        .frame(width: size, height: size)
        .padding(gap)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }
}
