// Ohia/Settings/AddAccountSheet.swift
// Post-onboarding add-account flow. Reuses the onboarding account picker
// and shared mail credential form so OAuth, password, detected, and manual
// accounts all pass through one setup path.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaMail
import OhiaScheduler
import OhiaIngest

struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(IMAPSessionManager.self) private var sessionManager: IMAPSessionManager?
    @AppStorage(ContentLanguagesStore.defaultsKey, store: OhiaSharedDefaults.store)
    private var activeLanguagesData = Data()
    @Query private var existingAccounts: [Account]

    @State private var discoveryService = AccountDiscoveryService()
    @State private var discovered: [DiscoveredAccount] = []
    @State private var selectedAccount: DiscoveredAccount?
    @State private var selectedHistoryPreset = HistoryIngestionPreset.defaultPreset
    @State private var selectedColorIndex = AccountColorPalette.defaultIndex
    @State private var isLoading = true
    @State private var step: AddStep = .accountDiscovery
    @State private var persistedAccount: Account?
    @State private var historyConfiguredAt = Date()
    @State private var verifiedIMAPConfiguration: IMAPConnectionConfiguration?
    @State private var retainedHistoryEstimate: IMAPHistoryEstimate?
    @State private var historyEstimateController = RemoteHistoryEstimateController()
    @State private var selectedLanguages: [String] = []

    @State private var showManualEntry = false
    @State private var manualEmail = ""
    @State private var manualDisplayName = ""
    @State private var manualImapHost = ""
    @State private var manualImapPort = "993"
    @State private var manualUsername = ""
    @State private var manualPassword = ""

    enum AddStep: CaseIterable {
        case accountDiscovery
        case mailSetup
        case historySelection
        case languageSelection
        case ready
    }

    static let stepOrder = AddStep.allCases

    private var availableAccounts: [DiscoveredAccount] {
        let configuredEmails = Set(existingAccounts.map { $0.emailAddress.lowercased() })
        return discovered.filter { !configuredEmails.contains($0.emailAddress.lowercased()) }
    }

    private var baseEffectiveAccount: DiscoveredAccount? {
        if showManualEntry && !manualEmail.isEmpty {
            return DiscoveredAccount(
                emailAddress: manualEmail,
                displayName: manualDisplayName.isEmpty ? manualEmail : manualDisplayName,
                identityDisplayName: manualDisplayName.isEmpty ? nil : manualDisplayName,
                source: .manual,
                imapHost: manualImapHost,
                imapPort: Int(manualImapPort),
                imapUsername: manualUsername.isEmpty ? manualEmail : manualUsername,
                imapSecurity: .tls
            )
        }
        return selectedAccount
    }

    private var effectiveAccount: DiscoveredAccount? {
        baseEffectiveAccount
    }

    var body: some View {
        Group {
            switch step {
            case .accountDiscovery:
                AccountDiscoveryStepView(
                    context: .addAccount,
                    accounts: availableAccounts,
                    selectedAccount: $selectedAccount,
                    showManualEntry: $showManualEntry,
                    manualEmail: $manualEmail,
                    manualDisplayName: $manualDisplayName,
                    manualImapHost: $manualImapHost,
                    manualImapPort: $manualImapPort,
                    manualUsername: $manualUsername,
                    manualPassword: $manualPassword,
                    selectedColorIndex: $selectedColorIndex,
                    isLoading: isLoading,
                    onContinue: advanceFromAccountDiscovery,
                    onRefresh: {
                        Task { await runDiscovery() }
                    }
                )

            case .mailSetup:
                if let discovered = effectiveAccount, let account = persistedAccount {
                    MailSetupStepView(
                        discoveredAccount: discovered,
                        account: account,
                        initialPassword: showManualEntry ? manualPassword : "",
                        onContinue: { configuration in
                            acceptVerifiedMailSetup(
                                configuration,
                                authenticatedAccountID: account.id
                            )
                        }
                    )
                } else {
                    Color.clear.onAppear { step = .accountDiscovery }
                }

            case .historySelection:
                if let account = persistedAccount,
                   let configuration = verifiedIMAPConfiguration {
                    HistorySelectionStepView(
                        selection: $selectedHistoryPreset,
                        authenticatedAccountID: account.id,
                        configuration: configuration,
                        configuredAt: historyConfiguredAt,
                        controller: historyEstimateController,
                        onContinue: continueFromHistorySelection
                    )
                }

            case .languageSelection:
                LanguageSelectionStepView(
                    selectedLanguages: $selectedLanguages,
                    onContinue: continueFromLanguageSelection
                )

            case .ready:
                readySection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            cancelButton
                .padding(24)
        }
        .overlay(alignment: .bottomLeading) {
            if step != .accountDiscovery {
                backButton
                    .padding(.leading, 32)
                    .padding(.bottom, 34)
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 620, idealHeight: 680)
        .task { await runDiscovery() }
    }

    private var cancelButton: some View {
        SidebarCloseButton(label: "Cancel adding account") {
            cancel()
        }
    }

    private var backButton: some View {
        Button(action: goBack) {
            ZStack {
                Circle().fill(OhiaColors.surface(0.10))
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
            }
            .frame(width: 30, height: 30)
            .overlay { Circle().strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1) }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Back")
        .accessibilityLabel("Back")
        .keyboardShortcut("[", modifiers: .command)
    }

    private var readySection: some View {
        ZStack {
            NightSkyView(showsMilkyWay: false)
            NightSkyNebulaOverlay()

            VStack(spacing: 0) {
                Spacer()

                Text("Account connected")
                    .font(OhiaTypography.stepHeading)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.bottom, 28)

                // Summary card — same glass treatment as ReadyStepView.
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(accountColor)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(persistedAccount?.emailAddress ?? "The account")
                                .font(OhiaTypography.body)
                                .foregroundStyle(OhiaColors.textPrimary)
                            Text("Ohia will receive mail directly for this account.")
                                .font(OhiaTypography.caption)
                                .foregroundStyle(OhiaColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
                .background(OhiaColors.glassPanel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(OhiaColors.glassBorder, lineWidth: 1)
                )
                .frame(maxWidth: 440)
                .padding(.bottom, 32)

                Button(action: completeAddAccount) {
                    Text("Done")
                        .font(OhiaTypography.button)
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 40, verticalPadding: 12))

                Spacer()
            }
            .padding(.horizontal, 48)
        }
    }

    /// The account color the user picked on the discovery step, resolved to a
    /// SwiftUI color at full brightness so the summary envelope matches the
    /// swatch. Falls back to the palette default when unset.
    private var accountColor: Color {
        let paletteColor = AccountColorPalette.color(forIndex: selectedColorIndex)
        let rgb = AccountColorPalette.rgb(for: paletteColor, brightness: 1.0)
        return Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1.0)
    }

    private func advanceFromAccountDiscovery() {
        prepareMailSetup()
    }

    private func prepareMailSetup() {
        guard let discovered = baseEffectiveAccount else { return }
        if persistedAccount == nil {
            persistedAccount = Self.persistSelectedAccount(
                from: discovered,
                colorIndex: selectedColorIndex,
                in: modelContext
            )
        }
        if persistedAccount != nil {
            step = .mailSetup
        }
    }

    private func acceptVerifiedMailSetup(
        _ configuration: IMAPConnectionConfiguration,
        authenticatedAccountID: UUID
    ) {
        guard step == .mailSetup,
              persistedAccount?.id == authenticatedAccountID else { return }
        historyEstimateController.invalidateCachedEstimates(
            forAuthenticatedAccountID: authenticatedAccountID
        )
        verifiedIMAPConfiguration = configuration
        historyConfiguredAt = Date()
        retainedHistoryEstimate = nil
        step = .historySelection
    }

    private func continueFromHistorySelection() {
        guard let account = persistedAccount,
              let configuration = verifiedIMAPConfiguration else { return }
        let estimate = historyEstimateController.validatedEstimate(
            selection: selectedHistoryPreset,
            authenticatedAccountID: account.id,
            configuration: configuration,
            configuredAt: historyConfiguredAt
        )
        retainedHistoryEstimate = Self.persistHistorySelection(
            selectedHistoryPreset,
            configuredAt: historyConfiguredAt,
            estimate: estimate,
            for: account,
            in: modelContext
        )
        step = .languageSelection
    }

    private func continueFromLanguageSelection() {
        guard let account = persistedAccount,
              let data = Self.persistOrderedLanguages(
                selectedLanguages,
                existingGlobalData: activeLanguagesData,
                for: account,
                in: modelContext
              ) else { return }
        activeLanguagesData = data
        step = .ready
    }

    private func completeAddAccount() {
        guard let account = persistedAccount else { return }
        Self.beginInitialIMAPAcquisition(
            for: account,
            estimate: retainedHistoryEstimate,
            startSession: { account, estimate in
                sessionManager?.startSession(
                    for: account,
                    initialHistoryEstimate: estimate
                )
            }
        )
        dismiss()
    }

    private func goBack() {
        switch step {
        case .accountDiscovery:
            return
        case .mailSetup:
            if Self.discardPersistedAccount(persistedAccount, in: modelContext) {
                persistedAccount = nil
            }
            verifiedIMAPConfiguration = nil
            retainedHistoryEstimate = nil
            selectedLanguages = []
            step = .accountDiscovery
            Task { await runDiscovery() }
        case .historySelection:
            step = .mailSetup
        case .languageSelection:
            step = .historySelection
        case .ready:
            step = .languageSelection
        }
    }

    private func cancel() {
        _ = Self.discardPersistedAccount(persistedAccount, in: modelContext)
        persistedAccount = nil
        dismiss()
    }

    @MainActor
    static func persistSelectedAccount(
        from discovered: DiscoveredAccount,
        colorIndex: Int,
        in context: ModelContext
    ) -> Account? {
        let newAccount = Account(
            displayName: discovered.displayName,
            emailAddress: discovered.emailAddress
        )
        newAccount.colorIndex = colorIndex
        context.insert(newAccount)
        configure(newAccount, from: discovered, in: context)
        do {
            try context.save()
            return newAccount
        } catch {
            context.delete(newAccount)
            return nil
        }
    }

    private static func configure(
        _ account: Account,
        from discovered: DiscoveredAccount,
        in context: ModelContext
    ) {
        account.displayName = discovered.displayName
        account.imapHost = discovered.imapHost
        account.imapPort = discovered.imapPort
        account.imapUsername = discovered.imapUsername
        account.imapSecurity = discovered.imapSecurity
        account.smtpHost = discovered.smtpHost
        account.smtpPort = discovered.smtpPort
        account.smtpUsername = discovered.smtpUsername
        account.smtpSecurity = discovered.smtpSecurity
        _ = try? DiscoveredAccountIdentityApplier.apply(
            discovered: discovered,
            to: account,
            in: context
        )
    }

    @discardableResult
    @MainActor
    static func discardPersistedAccount(
        _ account: Account?,
        in context: ModelContext,
        deleteCredentialRef: ((String) -> Void)? = nil
    ) -> Bool {
        OnboardingView.discardPersistedAccountIfCrossingBoundary(
            returningTo: .accountDiscovery,
            persistedAccount: account,
            in: context,
            deleteCredentialRef: deleteCredentialRef
        )
    }

    @discardableResult
    @MainActor
    static func persistHistorySelection(
        _ preset: HistoryIngestionPreset,
        configuredAt: Date,
        estimate: IMAPHistoryEstimate?,
        for account: Account,
        in context: ModelContext
    ) -> IMAPHistoryEstimate? {
        OnboardingView.persistHistorySelection(
            preset,
            configuredAt: configuredAt,
            estimate: estimate,
            for: account,
            in: context
        )
    }

    static func mergedContentLanguageIDs(
        existing: [String],
        additions: [String]
    ) -> [String] {
        var merged = existing
        var seen = Set(existing)
        for identifier in OrderedLanguageSelectionState.canonicalized(additions)
            where seen.insert(identifier).inserted {
            merged.append(identifier)
        }
        return merged
    }

    @MainActor
    static func persistOrderedLanguages(
        _ identifiers: [String],
        existingGlobalData: Data,
        for account: Account,
        in context: ModelContext
    ) -> Data? {
        let ordered = OrderedLanguageSelectionState.canonicalized(identifiers)
        guard ordered.isEmpty == false else { return nil }
        account.draftLanguages = ordered
        try? context.save()
        return ContentLanguagesStore.encode(
            mergedContentLanguageIDs(
                existing: ContentLanguagesStore.decode(existingGlobalData),
                additions: ordered
            )
        )
    }

    @MainActor
    static func beginInitialIMAPAcquisition(
        for account: Account,
        estimate: IMAPHistoryEstimate?,
        startSession: (Account, IMAPHistoryEstimate?) -> Void
    ) {
        OnboardingView.beginInitialIMAPAcquisition(
            for: account,
            estimate: estimate,
            startSession: startSession
        )
    }

    private func runDiscovery() async {
        isLoading = true
        let refreshedAccounts = await discoveryService.discoverAccounts()
        discovered = refreshedAccounts
        if let selectedAccount, !showManualEntry {
            let configuredEmails = Set(existingAccounts.map { $0.emailAddress.lowercased() })
            self.selectedAccount = refreshedAccounts.first {
                let email = $0.emailAddress.lowercased()
                return email == selectedAccount.emailAddress.lowercased()
                    && !configuredEmails.contains(email)
            }
        }
        isLoading = false
    }
}
