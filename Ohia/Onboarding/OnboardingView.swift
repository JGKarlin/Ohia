import SwiftUI
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaMail
import OhiaML
import OhiaScheduler

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(IMAPSessionManager.self) private var imapSessionManager: IMAPSessionManager?
    @AppStorage("hasCompletedOnboarding", store: OhiaSharedDefaults.store)
    private var hasCompletedOnboarding = false
    @AppStorage(ContentLanguagesStore.defaultsKey, store: OhiaSharedDefaults.store)
    private var activeLanguagesData = Data()
    @AppStorage("summaryOutputLanguage", store: OhiaSharedDefaults.store)
    private var summaryOutputLanguage = ""
    @AppStorage("summarizationUseAppleIntelligence", store: OhiaSharedDefaults.store)
    private var useAppleIntelligence = true

    @State private var currentStep: WizardStep = .welcome
    // Actual visited-step stack for backward navigation. Recording the real
    // path (rather than reversing `resolvedDestination`) keeps Back correct
    // even when `.appleIntelligence` is dynamically skipped.
    @State private var stepHistory: [WizardStep] = []
    @State private var appleIntelligenceAvailability: AppleIntelligenceAvailability.State = .unknown
    private let appleIntelligenceAvailabilityProvider: () -> AppleIntelligenceAvailability.State

    // Account discovery state
    @State private var discoveryService = AccountDiscoveryService()
    @State private var discoveredAccounts: [DiscoveredAccount] = []
    @State private var isDiscovering = true
    @State private var selectedAccount: DiscoveredAccount?
    @State private var showManualEntry = false
    @State private var manualEmail = ""
    @State private var manualDisplayName = ""
    @State private var manualImapHost = ""
    @State private var manualImapPort = "993"
    @State private var manualUsername = ""
    @State private var manualPassword = ""
    @State private var selectedHistoryPreset = HistoryIngestionPreset.defaultPreset
    @State private var historyConfiguredAt = Date()
    @State private var verifiedIMAPConfiguration: IMAPConnectionConfiguration?
    @State private var retainedHistoryEstimate: IMAPHistoryEstimate?
    @State private var historyEstimateController = RemoteHistoryEstimateController()
    // Color the user picked for the account being onboarded. Seeded with the
    // next-unused palette index when the user reaches `.accountDiscovery`;
    // remains user-overridable for the rest of the flow. `createAccount`
    // writes it to `Account.colorIndex` at the `.mailSetup` transition.
    @State private var selectedColorIndex: Int? = nil

    // Explicit ordered language selection; the first identifier is primary.
    @State private var selectedLanguages: [String] = []

    @State private var persistedAccount: Account? = nil

    init(
        appleIntelligenceAvailabilityProvider: @escaping () -> AppleIntelligenceAvailability.State = {
            AppleIntelligenceAvailability.current()
        }
    ) {
        self.appleIntelligenceAvailabilityProvider = appleIntelligenceAvailabilityProvider
    }

    var body: some View {
        // Back lives once at the wizard level (not per step). Forcing the
        // step content to fill the window and pinning Back to a full-window
        // overlay puts it in the same window bottom-left corner on every
        // step — even mail-setup, whose content is a centered 600pt column
        // that doesn't itself span the window.
        stepContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                // Back appears only when there's a meaningful step to return
                // to. The Welcome splash carries no inputs, so a Back that
                // only lands there is a no-op — hidden. The first interactive
                // step (whose sole predecessor is Welcome) shows no Back;
                // every later step does, letting the user revise a choice.
                if showsBackButton {
                    backButton
                        .padding(.leading, 32)
                        .padding(.bottom, 34)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentStep)
            // Force every native control (text-field focus rings, pickers,
            // selection, spinners) off the default macOS system blue onto the
            // Ohia accent (green light / yellow dark). No default blue anywhere.
            .tint(OhiaColors.chipActiveForeground)
    }

    // Back is offered only when the immediate predecessor is a step worth
    // returning to (see `isReturnable`). The Welcome splash carries no inputs,
    // and a *confirmed* Apple Intelligence step auto-advances the instant it
    // reappears — so neither is a meaningful Back target.
    private var showsBackButton: Bool {
        guard let previous = stepHistory.last else { return false }
        return isReturnable(previous)
    }

    private func isReturnable(_ step: WizardStep) -> Bool {
        Self.isReturnableStep(step, appleIntelligenceAvailability: appleIntelligenceAvailability)
    }

    /// Whether navigating Back to `step` lands somewhere meaningful.
    ///
    /// The Welcome splash carries no inputs, so a Back that only lands there is
    /// a no-op. A confirmed Apple Intelligence step is worse than a no-op: it
    /// auto-advances the moment it reappears (its `.task` / `didBecomeActive`
    /// re-detect availability and call `onContinue`), so a Back that lands on it
    /// bounces straight forward. Once Apple Intelligence is confirmed the step
    /// is non-returnable, which hides Back on the account step that follows it.
    /// Every other step is a real, revisable choice.
    static func isReturnableStep(
        _ step: WizardStep,
        appleIntelligenceAvailability: AppleIntelligenceAvailability.State
    ) -> Bool {
        switch step {
        case .welcome:
            return false
        case .appleIntelligence:
            return AppleIntelligenceOnboardingGate.shouldShowStep(for: appleIntelligenceAvailability)
        default:
            return true
        }
    }

    private var backButton: some View {
        // Same chevron-disc back affordance used across Constellation surfaces —
        // plain chevron, no word, no emblem framing.
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

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch currentStep {
            case .welcome:
                WelcomeStepView(onContinue: advanceStep)

            case .accountDiscovery:
                AccountDiscoveryStepView(
                    context: .onboarding,
                    accounts: discoveredAccounts,
                    selectedAccount: $selectedAccount,
                    showManualEntry: $showManualEntry,
                    manualEmail: $manualEmail,
                    manualDisplayName: $manualDisplayName,
                    manualImapHost: $manualImapHost,
                    manualImapPort: $manualImapPort,
                    manualUsername: $manualUsername,
                    manualPassword: $manualPassword,
                    selectedColorIndex: Binding(
                        get: { selectedColorIndex ?? AccountColorPalette.defaultIndex },
                        set: { selectedColorIndex = $0 }
                    ),
                    isLoading: isDiscovering,
                    onContinue: advanceStep,
                    onRefresh: {
                        Task { await discoverAccounts() }
                    }
                )

            case .mailSetup:
                if let discovered = effectiveAccount, let account = persistedAccount {
                    MailSetupStepView(
                        discoveredAccount: discovered,
                        account: account,
                        initialPassword: showManualEntry ? manualPassword : "",
                        onContinue: { configuration in
                            advanceAfterVerifiedMailSetup(
                                configuration,
                                authenticatedAccountID: account.id
                            )
                        }
                    )
                } else {
                    // Shouldn't happen — advanceStep guards create an account.
                    // Skip forward on the next run loop.
                    Color.clear.onAppear { advanceStep() }
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

            case .appleIntelligence:
                AppleIntelligenceStepView(
                    onContinue: advanceStep,
                    initialAvailability: appleIntelligenceAvailability,
                    availabilityProvider: appleIntelligenceAvailabilityProvider
                )

            case .ready:
                ReadyStepView(
                    selectedAccount: effectiveAccount,
                    selectedColorIndex: selectedColorIndex,
                    selectedLanguages: selectedLanguages,
                    onPrepareModel: { model, mode in
                        ModelManager.setSelectedGenerationModelMode(mode)
                        ModelManager.setSelectedGenerationModelID(model.modelId)
                        NotificationCenter.default.post(
                            name: .ohiaPrepareOnboardingModels,
                            object: nil,
                            userInfo: ["modelID": model.modelId]
                        )
                    },
                    onBegin: completeOnboarding
                )
            }
        }
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

    private func advanceStep() {
        guard currentStep.canAdvance(
            selectedAccount: effectiveAccount,
            selectedLanguages: selectedLanguages
        ) else { return }

        // Capture Apple Intelligence availability at the moment we leave its
        // step. `resolvedDestination` only refreshes this when *entering* the
        // step — where it's not-yet-available, which is exactly why the step
        // shows. The user then enables it in System Settings and advances;
        // recording the now-confirmed state here lets `isReturnable` recognize
        // the step as a dead Back target and hide Back on the account step.
        if currentStep == .appleIntelligence {
            appleIntelligenceAvailability = appleIntelligenceAvailabilityProvider()
        }

        if let next = currentStep.next {
            let destination = resolvedDestination(startingAt: next)
            stepHistory.append(currentStep)
            prepareForStep(destination)
            currentStep = destination
        }
    }

    private func goBack() {
        // Only navigate when the immediate predecessor is a real Back target —
        // mirrors `showsBackButton` so the ⌘[ shortcut can't strand the user on
        // a confirmed Apple Intelligence step (which would auto-advance away).
        guard let previous = stepHistory.last, isReturnable(previous) else { return }
        stepHistory.removeLast()
        if previous.isBeforeAccountPersistence {
            if Self.discardPersistedAccountIfCrossingBoundary(
                returningTo: previous,
                persistedAccount: persistedAccount,
                in: modelContext
            ) {
                persistedAccount = nil
            }
            verifiedIMAPConfiguration = nil
            retainedHistoryEstimate = nil
            selectedLanguages = []
        }
        if previous == .accountDiscovery {
            Task { await discoverAccounts() }
        }
        currentStep = previous
    }

    private func resolvedDestination(startingAt step: WizardStep) -> WizardStep {
        if step == .appleIntelligence {
            let availability = appleIntelligenceAvailabilityProvider()
            appleIntelligenceAvailability = availability
            if AppleIntelligenceOnboardingGate.shouldShowStep(for: availability) {
                return .appleIntelligence
            }
            useAppleIntelligence = true
            return .accountDiscovery
        }

        return step
    }

    private func prepareForStep(_ step: WizardStep) {
        if step == .accountDiscovery {
            // Clear accounts left behind by an abandoned earlier attempt before
            // the picker (and its color reservation) renders, so a dead account
            // never greys out a hue or lingers into the finished app. Forward
            // entry only (goBack doesn't call prepareForStep); crossing Back to
            // this step has already discarded the abandoned account directly.
            purgeOnboardingOrphanAccounts(keeping: persistedAccount?.id)
            Task { await discoverAccounts() }
            if selectedColorIndex == nil {
                let existing = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
                let used: Set<Int> = Set(existing.compactMap { $0.colorIndex })
                selectedColorIndex = AccountColorPalette.nextIndex(after: used)
            }
        }
        if step == .mailSetup {
            // Persist the selected account now so verified mail setup can save
            // its connection fields. Initial acquisition remains deferred to
            // the Ready transition, after history and languages are durable.
            if persistedAccount == nil {
                persistedAccount = createAccount()
            }
        }
    }

    private func createAccount() -> Account? {
        guard let effective = effectiveAccount else { return nil }
        let discovered = effective

        // Keep account creation idempotent if the transition is invoked twice;
        // abandoned prior attempts are purged before account discovery.
        let all = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        let resolvedColorIndex = selectedColorIndex
            ?? AccountColorPalette.nextIndex(after: Set(all.compactMap { $0.colorIndex }))
        let target: Account
        if let existing = all.first(where: { $0.emailAddress == discovered.emailAddress }) {
            existing.colorIndex = resolvedColorIndex
            configure(existing, from: discovered)
            target = existing
        } else {
            let newAccount = Account(
                displayName: discovered.displayName,
                emailAddress: discovered.emailAddress
            )
            newAccount.colorIndex = resolvedColorIndex
            modelContext.insert(newAccount)
            configure(newAccount, from: discovered)
            target = newAccount
        }

        // Onboarding commits to exactly one account. Drop any sibling left by an
        // earlier, different-email selection this run (reachable now that Back
        // returns to account selection) so it can't survive as a phantom
        // account or keep its color reserved.
        purgeOnboardingOrphanAccounts(keeping: target.id)
        try? modelContext.save()
        return target
    }

    private func purgeOnboardingOrphanAccounts(keeping keepID: UUID?) {
        Self.purgeOrphanAccounts(
            in: modelContext,
            keeping: keepID,
            hasCompletedOnboarding: hasCompletedOnboarding
        )
    }

    /// Crossing Back from persisted mail setup to account discovery abandons
    /// exactly the in-progress account. Cleanup happens before the view drops
    /// its reference so no row or credential survives the boundary.
    @discardableResult
    @MainActor
    static func discardPersistedAccountIfCrossingBoundary(
        returningTo step: WizardStep,
        persistedAccount: Account?,
        in context: ModelContext,
        deleteCredentialRef: ((String) -> Void)? = nil
    ) -> Bool {
        guard step.isBeforeAccountPersistence, let account = persistedAccount else {
            return false
        }
        let delete = deleteCredentialRef ?? { clearStoredCredential(ref: $0) }
        let refs = [account.keychainRef, account.smtpKeychainRef, account.imapKeychainRef]
            .compactMap { $0 }
        for ref in refs {
            delete(ref)
        }
        context.delete(account)
        try? context.save()
        return true
    }

    /// Removes accounts left behind by an abandoned onboarding attempt, keeping
    /// only `keepID` (the account currently being onboarded, if any). Returns
    /// the number removed.
    ///
    /// Gated on `hasCompletedOnboarding == false`: while onboarding has never
    /// finished, every persisted Account is an orphan from a prior incomplete
    /// run — Dev Reset wipes the store and removing the last account clears the
    /// flag, so no completed account can coexist with it. Such orphans carry no
    /// ingested messages (ingestion is deferred until onboarding completes), so
    /// deletion loses nothing; SwiftData cascades remove their identities and
    /// folder state, and each removed account's Keychain credentials are cleared
    /// so OAuth tokens / passwords don't outlive the row.
    @discardableResult
    @MainActor
    static func purgeOrphanAccounts(
        in context: ModelContext,
        keeping keepID: UUID?,
        hasCompletedOnboarding: Bool
    ) -> Int {
        guard !hasCompletedOnboarding else { return 0 }
        let existing = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var removed = 0
        for account in existing where account.id != keepID {
            clearStoredCredentials(for: account)
            context.delete(account)
            removed += 1
        }
        if removed > 0 {
            try? context.save()
        }
        return removed
    }

    /// Best-effort removal of an account's Keychain entries (OAuth tokens, SMTP
    /// and IMAP passwords) across all three credential services, so a purged
    /// orphan leaves no secrets behind.
    private static func clearStoredCredentials(for account: Account) {
        let refs = [account.keychainRef, account.smtpKeychainRef, account.imapKeychainRef]
            .compactMap { $0 }
        for ref in refs {
            clearStoredCredential(ref: ref)
        }
    }

    private static func clearStoredCredential(ref: String) {
        try? KeychainHelpers.delete(service: OAuthTokenStore.service, account: ref)
        try? KeychainHelpers.delete(service: SMTPCredentials.service, account: ref)
        try? KeychainHelpers.delete(service: IMAPCredentials.service, account: ref)
    }

    private func configure(_ account: Account, from discovered: DiscoveredAccount) {
        account.displayName = discovered.displayName
        account.imapHost = discovered.imapHost
        account.imapPort = discovered.imapPort
        account.imapUsername = discovered.imapUsername
        account.imapSecurity = discovered.imapSecurity
        if let smtpHost = discovered.smtpHost {
            account.smtpHost = smtpHost
        }
        if let smtpPort = discovered.smtpPort {
            account.smtpPort = smtpPort
        }
        if let smtpUsername = discovered.smtpUsername {
            account.smtpUsername = smtpUsername
        }
        if let smtpSecurity = discovered.smtpSecurity {
            account.smtpSecurity = smtpSecurity
        }
        _ = try? DiscoveredAccountIdentityApplier.apply(
            discovered: discovered,
            to: account,
            in: modelContext
        )
    }

    private func discoverAccounts() async {
        isDiscovering = true
        let refreshedAccounts = await discoveryService.discoverAccounts()
        discoveredAccounts = refreshedAccounts
        if let selectedAccount, !showManualEntry {
            self.selectedAccount = refreshedAccounts.first {
                $0.emailAddress.caseInsensitiveCompare(selectedAccount.emailAddress) == .orderedSame
            }
        }
        isDiscovering = false
    }

    private func advanceAfterVerifiedMailSetup(
        _ configuration: IMAPConnectionConfiguration,
        authenticatedAccountID: UUID
    ) {
        guard currentStep == .mailSetup,
              persistedAccount?.id == authenticatedAccountID else { return }
        historyEstimateController.invalidateCachedEstimates(
            forAuthenticatedAccountID: authenticatedAccountID
        )
        verifiedIMAPConfiguration = configuration
        historyConfiguredAt = Date()
        retainedHistoryEstimate = nil
        advanceStep()
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
        advanceStep()
    }

    private func continueFromLanguageSelection() {
        guard let account = persistedAccount,
              let data = Self.persistOrderedLanguages(
                selectedLanguages,
                for: account,
                in: modelContext
              ) else { return }
        activeLanguagesData = data
        if summaryOutputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let primaryLanguage = selectedLanguages.first {
            summaryOutputLanguage = primaryLanguage
        }
        advanceStep()
    }

    private func completeOnboarding() {
        guard let account = persistedAccount else { return }
        Self.beginInitialIMAPAcquisition(
            for: account,
            estimate: retainedHistoryEstimate,
            startSession: { account, estimate in
                imapSessionManager?.startSession(
                    for: account,
                    initialHistoryEstimate: estimate
                )
            }
        )
        hasCompletedOnboarding = true
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
        let lowerBound = preset.lowerBound(anchoredAt: configuredAt)

        for folder in account.imapFolderStates {
            context.delete(folder)
        }
        account.ingestionLowerBoundAt = lowerBound
        account.ingestionWindowPresetRaw = preset.rawValue

        guard let estimate,
              estimate.lowerBound == lowerBound,
              estimate.folderWork.allSatisfy({
                  $0.folderName.isEmpty == false
                      && $0.uidValidity > 0
                      && $0.uidNext > 0
                      && $0.candidateUIDCount >= 0
              }) else {
            try? context.save()
            return nil
        }

        var seenFolders = Set<String>()
        for work in estimate.folderWork where seenFolders.insert(work.folderName).inserted {
            let folder = IMAPFolderState(
                account: account,
                folderName: work.folderName,
                attributes: work.attributes,
                uidValidity: work.uidValidity
            )
            folder.uidNextAtLastSelect = work.uidNext
            folder.lowestFetchedUID = work.uidNext
            folder.backfillLowerBoundAt = lowerBound
            folder.inScopeMessageCountAtLastSelect = work.candidateUIDCount
            folder.initialImportUIDWorkTotal = work.candidateUIDCount
            folder.initialImportUIDWorkRemaining = work.candidateUIDCount
            folder.initialImportSnapshotUIDValidity = work.uidValidity
            context.insert(folder)
        }
        try? context.save()
        return estimate
    }

    @MainActor
    static func persistOrderedLanguages(
        _ identifiers: [String],
        for account: Account,
        in context: ModelContext
    ) -> Data? {
        let ordered = OrderedLanguageSelectionState.canonicalized(identifiers)
        guard ordered.isEmpty == false,
              let data = ContentLanguagesStore.encode(ordered) else { return nil }
        account.draftLanguages = ordered
        try? context.save()
        return data
    }

    @MainActor
    static func beginInitialIMAPAcquisition(
        for account: Account,
        estimate: IMAPHistoryEstimate?,
        startSession: (Account, IMAPHistoryEstimate?) -> Void
    ) {
        startSession(account, estimate)
    }
}
