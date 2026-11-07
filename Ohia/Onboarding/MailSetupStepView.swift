// Ohia/Onboarding/MailSetupStepView.swift
import SwiftUI
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaMail

struct MailSetupStepView: View {
    let discoveredAccount: DiscoveredAccount
    let account: Account
    let initialPassword: String
    let onContinue: (IMAPConnectionConfiguration) -> Void

    @State private var formState: SMTPConfigFormState
    @State private var appliedDiscoveryHints = false

    init(
        discoveredAccount: DiscoveredAccount,
        account: Account,
        initialPassword: String = "",
        onContinue: @escaping (IMAPConnectionConfiguration) -> Void
    ) {
        self.discoveredAccount = discoveredAccount
        self.account = account
        self.initialPassword = initialPassword
        self.onContinue = onContinue
        _formState = State(initialValue: SMTPConfigFormState(emailAddress: account.emailAddress))
    }

    var body: some View {
        ZStack {
            // Same nebula-on-starfield backdrop as the account picker — no
            // Milky Way band. Matches the rest of the form-heavy wizard steps.
            NightSkyView(showsMilkyWay: false)
            NightSkyNebulaOverlay()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    SMTPConfigFormView(
                        state: formState,
                        account: account,
                        requiresFreshOAuth: false,
                        saveButtonTitle: "Continue",
                        onSave: onContinue
                    )
                }
                // No enclosing card — content floats directly over the
                // starfield, matching HistorySelectionStepView. The OAuth
                // status row inside SMTPConfigFormView keeps its own thin
                // border since it conveys live sign-in state.
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
                .frame(maxWidth: 600)
                // Fill the scroll view horizontally so content and the
                // wizard-level Back overlay both resolve against the window.
                .frame(maxWidth: .infinity)
            }
            // Center compact OAuth content while keeping the expanded password
            // and server form scrollable when it exceeds the window height.
            .defaultScrollAnchor(.center, for: .alignment)
        }
        .task(id: account.id) {
            guard !appliedDiscoveryHints else { return }
            appliedDiscoveryHints = true
            formState.applyDiscoveryHints(discoveredAccount)
            formState.applyInitialPassword(initialPassword)
            formState.applyProviderDefaults()
        }
    }

    private var header: some View {
        let style = AccountIcon.style(forEmail: account.emailAddress)
        return HStack(alignment: .top, spacing: 14) {
            AccountGlyphImage(glyph: style.glyph, size: 32)
                .foregroundStyle(style.tint)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(headerTitle)
                    .font(OhiaTypography.stepHeading)
                    .foregroundStyle(OhiaColors.textPrimary)
                Text(headerSubtitle)
                    .font(OhiaTypography.body)
                    .foregroundStyle(OhiaColors.textPrimary)
            }
        }
    }

    private var headerTitle: String {
        switch formState.oauthProviderID {
        case .gmail:     return "Sign in with Google"
        case .microsoft: return "Sign in with Microsoft"
        case .none:      return "Connect this account"
        }
    }

    private var headerSubtitle: String {
        switch formState.oauthProviderID {
        case .gmail, .microsoft:
            return "Approve access for \(account.emailAddress). Your usual provider sign-in opens in the browser."
        case .none:
            return "Use the app-specific password or mail password your provider gives you for \(account.emailAddress)."
        }
    }
}
