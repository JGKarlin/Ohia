import SwiftUI
import OhiaCore
import OhiaML

struct ProjectConfigurationHeaderPresentation: Equatable {
    let title: String

    static func make(stage: ProjectConfigurationStage) -> Self {
        Self(
            title: stage == .configure ? "Configure Project" : "Review Project"
        )
    }
}

struct ProjectConfigurationNavigationGroup: Equatable, Identifiable, Sendable {
    let title: String
    let sections: [ProjectConfigurationSection]

    var id: String { title }
}

nonisolated struct ProjectAccountLanguageConfiguration: Equatable, Sendable {
    let accountID: UUID
    let languageIDs: [String]
}

nonisolated enum ProjectLanguageConfigurationPresentation {
    static func configuredLanguageIDs(
        accounts: [ProjectAccountLanguageConfiguration],
        selectedAccountIDs: Set<UUID>,
        fallbackLanguageIDs: [String]
    ) -> [String] {
        let scopedAccounts = selectedAccountIDs.isEmpty
            ? accounts
            : accounts.filter { selectedAccountIDs.contains($0.accountID) }
        let inherited = scopedAccounts.isEmpty
            ? fallbackLanguageIDs
            : scopedAccounts.flatMap {
                $0.languageIDs.isEmpty ? fallbackLanguageIDs : $0.languageIDs
            }
        let identifiers = Set(inherited.compactMap(ContentLanguageOption.supportedID(for:)))
        return identifiers.sorted { lhs, rhs in
            let lhsName = ContentLanguageOption.option(for: lhs)?.displayName ?? lhs
            let rhsName = ContentLanguageOption.option(for: rhs)?.displayName ?? rhs
            let comparison = lhsName.localizedStandardCompare(rhsName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs < rhs
        }
    }

    static func toggledLanguageIDs(
        current: Set<String>,
        languageID: String,
        configured: Set<String>
    ) -> Set<String> {
        var result = displayedLanguageIDs(
            persisted: current,
            configured: configured
        )
        if result.contains(languageID) {
            result.remove(languageID)
        } else {
            result.insert(languageID)
        }
        return result == configured ? [] : result
    }

    static func displayedLanguageIDs(
        persisted: Set<String>,
        configured: Set<String>
    ) -> Set<String> {
        persisted.isEmpty ? configured : persisted.intersection(configured)
    }

    static func reconciledLanguageIDs(
        current: Set<String>,
        configured: Set<String>
    ) -> Set<String> {
        guard configured.count > 1 else { return [] }
        let reconciled = current.intersection(configured)
        return reconciled == configured ? [] : reconciled
    }
}

enum ProjectConfigurationNavigation {
    static let groups: [ProjectConfigurationNavigationGroup] = [
        ProjectConfigurationNavigationGroup(
            title: "Project",
            sections: [.projectName, .accountScope, .language]
        ),
        ProjectConfigurationNavigationGroup(
            title: "Automatic Membership",
            sections: [.correspondents, .lists, .category]
        ),
        ProjectConfigurationNavigationGroup(
            title: "Message Criteria",
            sections: [
                .keywords,
                .tags,
            ]
        ),
        ProjectConfigurationNavigationGroup(
            title: "Add to Project",
            sections: [.threads, .messages]
        ),
    ]

    static func visibleGroups(
        configuredContentLanguageIDs: [String]
    ) -> [ProjectConfigurationNavigationGroup] {
        let showsLanguage = Set(configuredContentLanguageIDs).count > 1
        return groups.map { group in
            ProjectConfigurationNavigationGroup(
                title: group.title,
                sections: showsLanguage
                    ? group.sections
                    : group.sections.filter { $0 != .language }
            )
        }
    }
}

enum ProjectConfigurationFooterAction: CaseIterable, Equatable, Sendable {
    case discardDraft
    case reviewChanges
    case backToConfiguration
    case createProject
    case saveChanges
    case includeEarlierMail

    var title: String {
        switch self {
        case .discardDraft: "Discard Draft"
        case .reviewChanges: "Review Changes"
        case .backToConfiguration: "Edit Configuration"
        case .createProject: "Create Project"
        case .saveChanges: "Save Changes"
        case .includeEarlierMail: "Include Earlier Mail"
        }
    }
}

enum ProjectConfigurationFinalActionBehavior: Equatable, Sendable {
    case acknowledgeRefreshedReview
    case saveReviewedConfiguration
}

struct ProjectConfigurationFooterPresentation: Equatable {
    let reviewTitle: String
    let saveTitle: String
    let canSave: Bool
    let canPerformFinalAction: Bool
    let canNavigateAway: Bool
    let finalActionBehavior: ProjectConfigurationFinalActionBehavior
    let statusCopy: String
    let actions: [ProjectConfigurationFooterAction]

    static func make(
        stage: ProjectConfigurationStage,
        status: ProjectConfigurationSaveStatus,
        isNewProject: Bool,
        hasPreview: Bool,
        validationIsValid: Bool?,
        reviewKind: ProjectConfigurationReviewKind = .configuration
    ) -> Self {
        let saveTitle = switch reviewKind {
        case .configuration:
            isNewProject ? "Create Project" : "Save Changes"
        case .includeEarlierMail:
            "Include Earlier Mail"
        }
        let isBusy = switch status {
        case .autosaving, .previewing, .saving: true
        default: false
        }
        let reviewIsValid = switch reviewKind {
        case .configuration:
            validationIsValid == true
        case .includeEarlierMail:
            true
        }
        let canSave = stage == .review
            && hasPreview
            && reviewIsValid
            && status != .reviewRequired
            && isBusy == false
        let finalActionBehavior: ProjectConfigurationFinalActionBehavior =
            status == .reviewRequired
                ? .acknowledgeRefreshedReview
                : .saveReviewedConfiguration
        let canPerformFinalAction = stage == .review
            && hasPreview
            && isBusy == false
            && (canSave || status == .reviewRequired)
        let canNavigateAway = status != .saving
        let actions: [ProjectConfigurationFooterAction]
        if stage == .configure {
            actions = [.discardDraft, .reviewChanges]
        } else {
            let finalAction: ProjectConfigurationFooterAction = switch reviewKind {
            case .configuration:
                isNewProject ? .createProject : .saveChanges
            case .includeEarlierMail:
                .includeEarlierMail
            }
            actions = [.backToConfiguration, finalAction]
        }

        let statusCopy: String = switch status {
        case .idle where stage == .review && hasPreview:
            "Review complete — choose \(saveTitle)"
        case .idle where stage == .review:
            "Review found configuration issues — return to Configure"
        case .idle where isNewProject:
            "Project not yet created — changes save only as a draft"
        case .idle:
            "Live project unchanged — changes save only as a draft"
        case .autosaving where isNewProject:
            "Saving draft — project not yet created"
        case .autosaving:
            "Saving draft — live project unchanged"
        case .draftSaved where isNewProject:
            "Draft Saved - Project not yet active"
        case .draftSaved:
            "Draft saved — live project unchanged"
        case .previewing:
            "Reviewing membership changes"
        case .saving where isNewProject:
            "Creating project"
        case .saving:
            "Saving project"
        case .reviewRequired:
            "Membership changed — inspect the refreshed review, then choose \(saveTitle) to confirm"
        case .failed(let message):
            message
        }

        return Self(
            reviewTitle: "Review Changes",
            saveTitle: saveTitle,
            canSave: canSave,
            canPerformFinalAction: canPerformFinalAction,
            canNavigateAway: canNavigateAway,
            finalActionBehavior: finalActionBehavior,
            statusCopy: statusCopy,
            actions: actions
        )
    }

    @MainActor
    func performFinalAction(on state: ProjectConfigurationState) async {
        switch finalActionBehavior {
        case .acknowledgeRefreshedReview:
            await state.reviewChanges()
        case .saveReviewedConfiguration:
            await state.saveReviewedConfiguration()
        }
    }
}

struct ProjectConfigurationHeader: View {
    let projectName: String
    let stage: ProjectConfigurationStage

    var body: some View {
        let presentation = ProjectConfigurationHeaderPresentation.make(stage: stage)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                Text(projectName)
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(OhiaColors.composerPanelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
        }
    }
}

struct ProjectConfigurationFooter: View {
    @Bindable var state: ProjectConfigurationState
    let onDiscardDraft: () -> Void

    var body: some View {
        let presentation = ProjectConfigurationFooterPresentation.make(
            stage: state.stage,
            status: state.saveStatus,
            isNewProject: state.draft?.existingProjectID == nil,
            hasPreview: state.preview != nil,
            validationIsValid: state.validationReport?.isValid,
            reviewKind: state.reviewKind
        )
        HStack(spacing: 10) {
            ProjectConfigurationSaveStatusView(
                status: state.saveStatus,
                copy: presentation.statusCopy
            )
            Spacer(minLength: 12)
            ForEach(presentation.actions, id: \.title) { action in
                footerButton(action, presentation: presentation)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(OhiaColors.composerPanelBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func footerButton(
        _ action: ProjectConfigurationFooterAction,
        presentation: ProjectConfigurationFooterPresentation
    ) -> some View {
        switch action {
        case .discardDraft:
            Button {
                Task {
                    if await state.discardCurrentDraftForExit() {
                        onDiscardDraft()
                    }
                }
            } label: {
                Label(action.title, systemImage: "trash")
            }
            .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
            .disabled(state.draft == nil || state.isBusy)
        case .backToConfiguration:
            Button {
                state.returnToConfigure()
            } label: {
                Label(action.title, systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.emblem)
            .disabled(presentation.canNavigateAway == false)
        case .reviewChanges:
            Button {
                Task { await state.reviewChanges() }
            } label: {
                Label(action.title, systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.emblem)
            .disabled(state.draft == nil || state.isBusy)
        case .createProject:
            Button {
                Task { await presentation.performFinalAction(on: state) }
            } label: {
                Label(action.title, systemImage: "plus")
            }
            .buttonStyle(.emblem)
            .disabled(presentation.canPerformFinalAction == false)
            .help(presentation.canPerformFinalAction
                ? action.title
                : "Review the current changes before saving the project")
        case .saveChanges:
            Button {
                Task { await presentation.performFinalAction(on: state) }
            } label: {
                Label(action.title, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.emblem)
            .disabled(presentation.canPerformFinalAction == false)
            .help(presentation.canPerformFinalAction
                ? action.title
                : "Review the current changes before saving the project")
        case .includeEarlierMail:
            Button(action.title, systemImage: "clock.arrow.circlepath") {
                Task { await presentation.performFinalAction(on: state) }
            }
            .buttonStyle(.emblem)
            .disabled(presentation.canPerformFinalAction == false)
            .help(presentation.canPerformFinalAction
                ? action.title
                : "Review the current changes before saving the project")
        }
    }

}

struct ProjectConfigurationSaveStatusView: View {
    let status: ProjectConfigurationSaveStatus
    let copy: String

    var body: some View {
        HStack(spacing: 6) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(copy)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(2)
        }
    }

    private var isWorking: Bool {
        switch status {
        case .autosaving, .previewing, .saving: true
        default: false
        }
    }

    private var symbolName: String {
        switch status {
        case .failed: "exclamationmark.triangle.fill"
        case .reviewRequired: "arrow.clockwise.circle"
        case .draftSaved: "checkmark.circle.fill"
        default: "circle.dotted"
        }
    }

    private var tint: Color {
        switch status {
        case .failed: OhiaColors.ohiaRed
        case .reviewRequired: OhiaColors.ohiaYellow
        case .draftSaved: OhiaColors.ohiaYellow
        default: OhiaColors.textSecondary
        }
    }
}

struct ProjectConfigurationEmptyState: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(OhiaColors.textTertiary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(OhiaColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

extension MailProjectRuleFacet {
    var projectConfigurationTitle: String {
        switch self {
        case .invalid: "Invalid Criterion"
        case .account: "Account"
        case .correspondent: "Correspondent"
        case .mailingList: "List"
        case .fixedCategory: "Fixed Category"
        case .customCategory: "Custom Category"
        case .semanticTag: "Tag"
        case .language: "Language"
        case .subject: "Subject Keywords"
        case .body: "Body Keywords"
        case .attachmentFilename: "Attachment Filename"
        case .attachmentText: "Attachment Text"
        }
    }

    var projectConfigurationIsKeyword: Bool {
        switch self {
        case .subject, .body, .attachmentFilename, .attachmentText: true
        default: false
        }
    }
}

extension MailProjectConditionPolarity {
    var projectConfigurationTitle: String {
        self == .include ? "Include" : "Exclude"
    }
}

extension MailProjectValueQuantifier {
    var projectConfigurationTitle: String {
        self == .any ? "Any" : "All"
    }
}

extension MailProjectCorrespondentRole {
    var projectConfigurationTitle: String {
        switch self {
        case .from: "From"
        case .to: "To"
        case .cc: "Cc"
        case .bcc: "Bcc"
        case .involves: "Involves"
        }
    }
}

extension MailProjectKeywordOperator {
    var projectConfigurationTitle: String {
        switch self {
        case .containsPhrase: "Contains Phrase"
        case .anyWord: "Any Word"
        case .allWords: "All Words"
        }
    }
}

extension MailProjectKeywordScope {
    var projectConfigurationTitle: String {
        switch self {
        case .subject: "Subject"
        case .body: "Body"
        case .attachmentFilename: "Attachment Filename"
        case .attachmentText: "Attachment Text"
        }
    }
}

extension MailProjectHealth {
    var projectConfigurationTitle: String {
        switch self {
        case .healthy: "Healthy"
        case .needsAttention: "Needs Attention"
        case .membershipUpdatePending: "Membership Update Pending"
        }
    }
}

extension MailProjectValidationIssueCode {
    var projectConfigurationCopy: String {
        switch self {
        case .invalidFacet: "This criterion is no longer supported."
        case .invalidGroupKind: "This rule group is not supported."
        case .multipleSharedCriteriaGroups: "Keep all shared conditions in one Shared Criteria group."
        case .unsupportedSharedCriteriaFacet: "Move account and correspondent choices out of Shared Criteria."
        case .emptyMatchGroup: "Add at least one condition to this match group."
        case .emptyValues: "Choose at least one value for this condition."
        case .invalidCatalogValue: "This saved value is no longer available."
        case .missingCorrespondentRole: "Choose how the correspondent participates."
        case .unexpectedCorrespondentRole: "Remove the correspondent role from this condition."
        case .missingKeywordScopes: "Choose at least one keyword scope."
        case .missingKeywordOperator: "Choose a keyword operator."
        case .unexpectedKeywordConfiguration: "Remove keyword options from this condition."
        }
    }
}
