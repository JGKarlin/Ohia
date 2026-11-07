import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

struct ProjectConfigurationWorkspaceView: View {
    @Bindable var state: ProjectConfigurationState
    let exitRequestSequence: Int
    let onCancel: () -> Void
    let onSaved: (ProjectConfigurationSaveCompletion) -> Void

    @AppStorage(ContentLanguagesStore.defaultsKey, store: OhiaSharedDefaults.store)
    private var contentLanguagesData = Data()
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    var body: some View {
        VStack(spacing: 0) {
            ProjectConfigurationHeader(
                projectName: headerProjectName,
                stage: state.stage
            )

            Group {
                switch state.loadState {
                case .idle, .loading:
                    OhiaLoadingIndicator(accessibilityLabel: "Loading project configuration")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(OhiaColors.composerPanelBackground)
                case .failed(let message):
                    VStack(spacing: 14) {
                        ProjectConfigurationEmptyState(
                            title: "Configuration could not be opened",
                            detail: message,
                            symbolName: "exclamationmark.triangle"
                        )
                        if state.malformedDraftRecoveryAvailable {
                            Button("Discard and Continue", systemImage: "trash") {
                                Task { await state.discardCurrentDraftAndContinue() }
                            }
                            .buttonStyle(.emblem)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OhiaColors.composerPanelBackground)
                case .ready:
                    workspace
                }
            }

            ProjectConfigurationFooter(state: state, onDiscardDraft: onCancel)
        }
        .background(OhiaColors.composerPanelBackground)
        .environment(\.colorScheme, .dark)
        .tint(OhiaColors.chipActiveForeground)
        .settingsGroupBoxStyling()
        .task { await state.start() }
        .onChange(of: state.draftFingerprint) { _, _ in
            state.scheduleAutosave()
        }
        .onChange(of: state.completedSave) { _, completion in
            guard let completion else { return }
            onSaved(completion)
        }
        .onChange(of: exitRequestSequence) { _, _ in
            guard state.canNavigateAway else { return }
            cancel()
        }
        .onDisappear {
            Task { await state.persistDraftForWorkspaceDisappearance() }
        }
    }

    private var headerProjectName: String {
        let title = (state.draft?.displayName ?? "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return title.isEmpty ? "New Project" : title
    }

    private var workspace: some View {
        Group {
            if state.stage == .review {
                ProjectConfigurationReviewView(state: state)
            } else {
                HStack(spacing: 10) {
                    ProjectConfigurationSourcePane(state: state)
                        .frame(width: 220)
                    configurationPane
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ComposerNightSkyBackdrop())
    }

    private var configurationPane: some View {
        Group {
            switch state.selectedSection {
            case .projectName, .accountScope, .language, .correspondents, .lists:
                ScrollView {
                    configurationSettingsPage
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                }
            case .category:
                ProjectCategorySettingsView(state: state)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
            case .keywords:
                criteriaPage(.keywords)
            case .tags:
                criteriaPage(.tags)
            case .threads:
                ProjectExplicitMembershipView(state: state, targetKind: .thread)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            case .messages:
                ProjectExplicitMembershipView(state: state, targetKind: .message)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var configurationSettingsPage: some View {
        switch state.selectedSection {
        case .projectName:
            projectNamePane
        case .accountScope:
            accountScopePane
        case .language:
            languagePane
        case .correspondents:
            ProjectCorrespondentsEditorView(state: state)
        case .lists:
            ProjectMailingListsEditorView(state: state)
        case .category, .keywords, .tags, .threads, .messages:
            EmptyView()
        }
    }

    private func criteriaPage(_ page: ProjectAutomaticCriteriaPage) -> some View {
        ProjectMessageCriteriaView(state: state, page: page)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
    }

    private var projectNamePane: some View {
        OhiaSettingsCard("Project Name") {
            SettingsBlock {
                TextField(
                    "Project Name",
                    text: Binding(
                        get: { state.draft?.displayName ?? "" },
                        set: { state.setDisplayName($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, weight: .semibold))
                Text("Choose a concise name that will remain recognizable in the Projects workspace.")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
        }
    }

    private var accountScopePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            OhiaSettingsCard("Accounts") {
                SettingsBlock {
                    Text("Choose which accounts automatic matching and thread or message search may examine. Manual choices can remain visible exceptions.")
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
                SettingsRowDivider()
                accountSelectionRow(
                    title: "All Accounts",
                    detail: "Every configured account",
                    isSelected: state.draft?.accountIDs.isEmpty != false
                ) {
                    setAccountScope([])
                }
                ForEach(state.catalog?.accounts ?? []) { account in
                    SettingsRowDivider()
                    let accountID = UUID(uuidString: account.stableKey)
                    let isSelected = accountID.map {
                        state.draft?.accountIDs.contains($0) == true
                    } ?? false
                    accountSelectionRow(
                        title: account.displayName,
                        detail: "\(account.currentMatchCount) messages",
                        isSelected: isSelected
                    ) {
                        guard let accountID else { return }
                        var ids = state.draft?.accountIDs ?? []
                        if ids.contains(accountID) {
                            ids.remove(accountID)
                        } else {
                            ids.insert(accountID)
                        }
                        setAccountScope(ids)
                    }
                }
            }

            initialAutomaticIntakeCard
        }
    }

    private var languagePane: some View {
        OhiaSettingsCard("Language") {
            SettingsBlock {
                Text("Choose which of the selected accounts’ configured languages automatic membership may accept. Selecting every configured language adds no language restriction.")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
            SettingsRowDivider()
            SettingsBlock {
                LazyVGrid(
                    columns: languageGridColumns,
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(configuredLanguageOptions) { language in
                        languageChip(
                            title: language.displayName,
                            languageID: language.id,
                            isSelected: displayedSelectedLanguageIDs.contains(language.id)
                        )
                    }
                }
            }
        }
    }

    private func languageChip(
        title: String,
        languageID: String,
        isSelected: Bool
    ) -> some View {
        Button {
            setSelectedLanguageIDs(
                ProjectLanguageConfigurationPresentation.toggledLanguageIDs(
                    current: selectedLanguageIDs,
                    languageID: languageID,
                    configured: Set(configuredContentLanguageIDs)
                )
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(
                isSelected
                    ? OhiaColors.chipActiveForeground
                    : OhiaColors.textPrimary
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isSelected
                            ? OhiaColors.chipActiveBackground
                            : OhiaColors.buttonBackground
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected
                            ? OhiaColors.chipSelectedBorder
                            : OhiaColors.chipRestBorder,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var configuredContentLanguageIDs: [String] {
        configuredContentLanguageIDs(
            selectedAccountIDs: state.draft?.accountIDs ?? []
        )
    }

    private func configuredContentLanguageIDs(
        selectedAccountIDs: Set<UUID>
    ) -> [String] {
        ProjectLanguageConfigurationPresentation.configuredLanguageIDs(
            accounts: accounts.map {
                ProjectAccountLanguageConfiguration(
                    accountID: $0.id,
                    languageIDs: $0.draftLanguages
                )
            },
            selectedAccountIDs: selectedAccountIDs,
            fallbackLanguageIDs: ContentLanguagesStore.modelSupportedIDs(
                from: contentLanguagesData
            )
        )
    }

    private var configuredLanguageOptions: [ContentLanguageOption] {
        configuredContentLanguageIDs.compactMap(ContentLanguageOption.option(for:))
    }

    private var languageGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 120), spacing: 20),
            count: min(max(configuredLanguageOptions.count, 1), 4)
        )
    }

    private var languageConditions: [ProjectRuleConditionDraft] {
        (state.draft?.groups ?? [])
            .filter { $0.kind == .sharedCriteria }
            .flatMap(\.conditions)
            .filter { $0.facet == .language }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private var selectedLanguageIDs: Set<String> {
        Set(languageConditions
            .filter { $0.polarity == .include }
            .flatMap(\.values))
    }

    private var displayedSelectedLanguageIDs: Set<String> {
        ProjectLanguageConfigurationPresentation.displayedLanguageIDs(
            persisted: selectedLanguageIDs,
            configured: Set(configuredContentLanguageIDs)
        )
    }

    private func setSelectedLanguageIDs(_ selection: Set<String>) {
        let orderedSelection = configuredContentLanguageIDs.filter(selection.contains)
        guard orderedSelection.isEmpty == false else {
            for condition in languageConditions {
                state.removeSharedCondition(condition.id)
            }
            return
        }

        let existing = languageConditions.first
        let replacementID = existing?.id ?? UUID()
        state.upsertSharedCondition(ProjectRuleConditionDraft(
            id: replacementID,
            facet: .language,
            polarity: .include,
            quantifier: .any,
            values: orderedSelection,
            sortIndex: existing?.sortIndex ?? sharedConditionCount
        ))
        for condition in languageConditions where condition.id != replacementID {
            state.removeSharedCondition(condition.id)
        }
    }

    private func setAccountScope(_ accountIDs: Set<UUID>) {
        let reconciledLanguages = ProjectLanguageConfigurationPresentation
            .reconciledLanguageIDs(
                current: selectedLanguageIDs,
                configured: Set(configuredContentLanguageIDs(
                    selectedAccountIDs: accountIDs
                ))
            )
        state.setAccountScope(accountIDs)
        setSelectedLanguageIDs(reconciledLanguages)
    }

    private var sharedConditionCount: Int {
        (state.draft?.groups ?? [])
            .filter { $0.kind == .sharedCriteria }
            .flatMap(\.conditions)
            .count
    }

    @ViewBuilder
    private var initialAutomaticIntakeCard: some View {
        if let draft = state.draft, draft.existingProjectID == nil {
            OhiaSettingsCard("Initial Automatic Intake") {
                SettingsBlock {
                    Text("Choose how far back automatic matching begins inside the account scope. Manual thread and message choices remain independent.")
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)

                    Picker(
                        "Initial automatic intake",
                        selection: Binding(
                            get: { draft.intakeChoice },
                            set: { state.setInitialIntakeChoice($0) }
                        )
                    ) {
                        ForEach(ProjectInitialIntakeChoice.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        } else if let boundary = state.draft?.automaticIntakeStartAt {
            OhiaSettingsCard("Initial Automatic Intake") {
                SettingsBlock {
                    Text("New automatic matches are included from \(Self.dateFormatter.string(from: boundary)). This boundary stays fixed during ordinary edits.")
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)

                    Button("Include Earlier Mail", systemImage: "clock.arrow.circlepath") {
                        Task { await state.prepareIncludeEarlierMail() }
                    }
                    .buttonStyle(.emblem)
                    .disabled(state.isBusy)
                }
            }
        } else if state.draft?.existingProjectID != nil {
            OhiaSettingsCard("Initial Automatic Intake") {
                SettingsCaption("This project includes matching mail from the complete stored account scope.")
            }
        }
    }

    private func accountSelectionRow(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected
                            ? OhiaColors.chipActiveForeground
                            : OhiaColors.textTertiary
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(OhiaColors.textPrimary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func cancel() {
        guard state.canNavigateAway else { return }
        Task {
            if await state.persistDraftBeforeClosing() {
                onCancel()
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
