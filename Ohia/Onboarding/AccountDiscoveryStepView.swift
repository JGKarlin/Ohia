import SwiftUI
import AppKit
import OhiaCore
import OhiaIngest

struct AccountDiscoveryStepView: View {
    /// Which flow is hosting the picker. Onboarding frames the choice as the
    /// first account to start from; adding an account from Settings frames it
    /// as a new addition. Only the header copy differs — the provider and
    /// manual connection choices are shared.
    enum Context {
        case onboarding
        case addAccount
    }

    let context: Context
    let accounts: [DiscoveredAccount]
    @Binding var selectedAccount: DiscoveredAccount?
    @Binding var showManualEntry: Bool
    @Binding var manualEmail: String
    @Binding var manualDisplayName: String
    @Binding var manualImapHost: String
    @Binding var manualImapPort: String
    @Binding var manualUsername: String
    @Binding var manualPassword: String
    @Binding var selectedColorIndex: Int
    let isLoading: Bool
    let onContinue: () -> Void
    let onRefresh: (() -> Void)?
    private var canContinue: Bool {
        Self.canContinue(
            selectedAccount: selectedAccount,
            showManualEntry: showManualEntry,
            manualEmail: manualEmail,
            manualImapHost: manualImapHost,
            manualImapPort: manualImapPort,
            manualUsername: manualUsername
        )
    }

    static func showsAccountSetup(isLoading: Bool) -> Bool {
        isLoading == false
    }

    static func canContinue(
        selectedAccount: DiscoveredAccount?,
        showManualEntry: Bool,
        manualEmail: String,
        manualImapHost: String,
        manualImapPort: String,
        manualUsername: String
    ) -> Bool {
        if showManualEntry {
            guard let port = Int(manualImapPort), port > 0 else { return false }
            return !manualEmail.isEmpty && !manualImapHost.isEmpty && !manualUsername.isEmpty
        }
        return selectedAccount != nil
    }

    var body: some View {
        ZStack {
            // Nebula wash on a plain starfield — no Milky Way band (same pairing
            // as Composer and Constellation load). The band reads wrong behind
            // form-heavy wizard steps.
            NightSkyView(showsMilkyWay: false)
            NightSkyNebulaOverlay()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Header
                        VStack(spacing: 8) {
                            Text(context == .onboarding ? "Choose an account to start" : "Add an account")
                                .font(OhiaTypography.stepHeading)
                                .foregroundStyle(OhiaColors.textPrimary)

                            Text("Ohia reads your email — it never modifies your mailbox.")
                                .font(OhiaTypography.body)
                                .foregroundStyle(OhiaColors.textPrimary)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 32)
                        .padding(.horizontal, 48)

                        // Content area
                        if isLoading {
                            VStack(spacing: 16) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.large)
                                    .tint(OhiaColors.chipActiveForeground)
                                Text("Looking for email accounts on this Mac")
                                    .font(OhiaTypography.body)
                                    .foregroundStyle(OhiaColors.textPrimary)
                            }
                            .padding(.vertical, 60)
                        } else if Self.showsAccountSetup(isLoading: isLoading) {
                            VStack(spacing: 8) {
                                // Discovered accounts
                                ForEach(accounts) { account in
                                    AccountRowButton(
                                        account: account,
                                        isSelected: selectedAccount?.id == account.id
                                    ) {
                                        selectedAccount = account
                                        showManualEntry = false
                                    }
                                }

                                // Manual IMAP entry
                                ManualEntrySection(
                                    isExpanded: $showManualEntry,
                                    email: $manualEmail,
                                    displayName: $manualDisplayName,
                                    imapHost: $manualImapHost,
                                    imapPort: $manualImapPort,
                                    username: $manualUsername,
                                    password: $manualPassword,
                                    onExpand: {
                                        showManualEntry = true
                                        selectedAccount = nil
                                    }
                                )

                                InternetAccountsHandoffView(
                                    hasDiscoveredAccounts: !accounts.isEmpty,
                                    onOpen: openInternetAccountsSettings,
                                    onRefresh: onRefresh
                                )

                                // Always shown (not gated on selection) so the
                                // column's height — and its centered position
                                // in the ScrollView — never shifts the instant
                                // an account is picked. Choosing a color ahead
                                // of the account is harmless; the binding is
                                // independent of `selectedAccount`.
                                AccountColorPickerStrip(selectedIndex: $selectedColorIndex)
                                    .padding(.top, 14)
                            }
                            // Cap the column so rows don't stretch the full window
                            // width on large displays; centered, matching
                            // MailSetupStepView's 600pt column.
                            .padding(.horizontal, 24)
                            .frame(maxWidth: 600)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 40)
                }
                // Center the header+rows column when it's short (few
                // discovered accounts); scroll normally once the list
                // outgrows the window — same center-anchored pattern as
                // MailSetupStepView.
                .defaultScrollAnchor(.center, for: .alignment)

                // Continue button — emblem style (the app-wide button
                // idiom). Deliberately outside the ScrollView so it stays
                // reachable without scrolling even when a long discovered-
                // account list fills the window, matching every other step
                // in this wizard.
                Button(action: onContinue) {
                    Text("Continue")
                        .font(OhiaTypography.button)
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 40, verticalPadding: 12))
                .disabled(!canContinue)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
    }

    private func openInternetAccountsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.internetaccounts",
            "x-apple.systempreferences:com.apple.preference.internetaccounts",
            "x-apple.systempreferences:"
        ]
        for value in candidates {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

}

// MARK: - InternetAccountsHandoffView

private struct InternetAccountsHandoffView: View {
    let hasDiscoveredAccounts: Bool
    let onOpen: () -> Void
    let onRefresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OhiaColors.textSecondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("Add in Mac Internet Accounts")
                    .font(OhiaTypography.body)
                    .foregroundStyle(OhiaColors.textPrimary)

                Text(helpText)
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.emblem)
                    .help("Refresh after adding an account")
                }

                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Open Settings")
                            .font(OhiaTypography.button)
                    }
                }
                .buttonStyle(.emblem)
                .help("Open Mac Internet Accounts")
            }
        }
        .padding(14)
        // No fill — border only, matching the box-free wizard steps.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        )
    }

    private var helpText: String {
        if hasDiscoveredAccounts {
            return "If an account is missing, add or enable Mail in System Settings, then refresh."
        }
        return "Add a Mail account in System Settings, then refresh."
    }
}

// MARK: - AccountRowButton

private struct AccountRowButton: View {
    let account: DiscoveredAccount
    let isSelected: Bool
    let onSelect: () -> Void

    private var borderColor: Color {
        if isSelected {
            return OhiaColors.chipActiveForeground
        }
        return account.source == .manual ? OhiaColors.glassBorder : OhiaColors.chipActiveForeground.opacity(0.35)
    }

    var body: some View {
        let style = AccountIcon.style(forEmail: account.emailAddress)
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Radio indicator
                Circle()
                    .strokeBorder(isSelected ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .fill(OhiaColors.chipActiveForeground)
                            .frame(width: 10, height: 10)
                            .opacity(isSelected ? 1 : 0)
                    )

                // Provider brand glyph — same icon set the Constellation
                // filter chips use, so users learn the cue once.
                AccountGlyphImage(glyph: style.glyph, size: 20)
                    .foregroundStyle(style.tint)

                // Account info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(account.emailAddress)
                            .font(OhiaTypography.body)
                            .foregroundStyle(OhiaColors.textPrimary)

                        if let badge = sourceBadge {
                            Text(badge)
                                .font(OhiaTypography.caption)
                                .foregroundStyle(OhiaColors.chipActiveForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OhiaColors.chipActiveForeground.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    if account.displayName != account.emailAddress {
                        Text(account.displayName)
                            .font(OhiaTypography.caption)
                            .foregroundStyle(OhiaColors.textPrimary)
                    }
                }

                Spacer()
            }
            .padding(14)
            // No fill — border alone (brighter + bolder when selected)
            // carries the affordance, matching the box-free wizard steps.
            // contentShape keeps the whole row (including the trailing
            // Spacer) tappable now that there's no opaque background.
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var sourceBadge: String? {
        switch account.source {
        case .mailApp:
            return nil
        case .internetAccounts:
            return "Mac account"
        case .manual:
            return nil
        }
    }

}

// MARK: - ManualEntrySection

private struct ManualEntrySection: View {
    @Binding var isExpanded: Bool
    @Binding var email: String
    @Binding var displayName: String
    @Binding var imapHost: String
    @Binding var imapPort: String
    @Binding var username: String
    @Binding var password: String
    let onExpand: () -> Void

    var body: some View {
        // Once the user starts typing an email, light up the matching
        // brand glyph; otherwise show the generic envelope so the row
        // visually aligns with the discovered-account rows above.
        let style = email.isEmpty ? nil : AccountIcon.style(forEmail: email)
        VStack(spacing: 0) {
            // Header button
            Button(action: {
                if !isExpanded { onExpand() } else { isExpanded = false }
            }) {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                        .foregroundStyle(OhiaColors.textSecondary)
                        .frame(width: 18, height: 18)

                    if let style {
                        AccountGlyphImage(glyph: style.glyph, size: 20)
                            .foregroundStyle(style.tint)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect manually")
                            .font(OhiaTypography.body)
                            .foregroundStyle(OhiaColors.textPrimary)
                        Text("For custom mail servers")
                            .font(OhiaTypography.caption)
                            .foregroundStyle(OhiaColors.textPrimary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(OhiaColors.textTertiary)
                }
                .padding(14)
                // contentShape keeps the whole header row (including the
                // trailing Spacer) tappable now that there's no opaque
                // background behind it.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded form
            if isExpanded {
                VStack(spacing: 12) {
                    Divider()
                        .background(OhiaColors.glassBorder)
                        .padding(.horizontal, 14)

                    VStack(spacing: 10) {
                        ManualEntryField(label: "Display Name", placeholder: "Jane Appleseed", text: $displayName)
                        ManualEntryField(label: "Email", placeholder: "you@example.com", text: $email)
                        ManualEntryField(label: "IMAP Host", placeholder: "imap.example.com", text: $imapHost)
                        ManualEntryField(label: "Port", placeholder: "993", text: $imapPort)
                        ManualEntryField(label: "Username", placeholder: "you@example.com", text: $username)
                        ManualEntrySecureField(label: "Password", placeholder: "••••••••", text: $password)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
        // No fill — border only, matching the box-free wizard steps.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.glassBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        )
    }
}

// MARK: - ManualEntryField

private struct ManualEntryField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(OhiaTypography.caption)
                .foregroundStyle(OhiaColors.textSecondary)
                .frame(width: 90, alignment: .trailing)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(OhiaTypography.body)
                .foregroundStyle(OhiaColors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(OhiaColors.surface(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - ManualEntrySecureField

private struct ManualEntrySecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(OhiaTypography.caption)
                .foregroundStyle(OhiaColors.textSecondary)
                .frame(width: 90, alignment: .trailing)

            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(OhiaTypography.body)
                .foregroundStyle(OhiaColors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(OhiaColors.surface(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
