import SwiftUI
import OhiaCore
import OhiaML

struct ProjectMessageCriteriaSectionPresentation: Equatable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case categorical(ProjectRuleValuePickerSection)
        case keywords
    }

    let kind: Kind
    let title: String
    let allowsFreeCreation: Bool

    var id: String { title }

    var facet: MailProjectRuleFacet {
        switch kind {
        case .categorical(let section): section.facet
        case .keywords: .subject
        }
    }

    func contains(_ condition: ProjectRuleConditionDraft) -> Bool {
        switch kind {
        case .categorical(let section): condition.facet == section.facet
        case .keywords: condition.facet.projectConfigurationIsKeyword
        }
    }
}

enum ProjectTagsCriteriaPresentation {
    static let sections: [ProjectMessageCriteriaSectionPresentation] =
        ProjectRuleValuePickerSection.tagCases.map {
            ProjectMessageCriteriaSectionPresentation(
                kind: .categorical($0),
                title: $0.title,
                allowsFreeCreation: $0.allowsFreeCreation
            )
        }
}

nonisolated enum ProjectRelatedTagsPresentation: Equatable, Sendable {
    case loading
    case empty
    case recommendations

    static func make(
        isLoading: Bool,
        recommendationCount: Int
    ) -> Self {
        if isLoading { return .loading }
        return recommendationCount == 0 ? .empty : .recommendations
    }
}

enum ProjectKeywordsCriteriaPresentation {
    static let scopes: [MailProjectKeywordScope] = [.subject, .body]
    static let polarities: [MailProjectConditionPolarity] = [.include, .exclude]
    static let addTermTitle = "Term"

    static let sections = [
        ProjectMessageCriteriaSectionPresentation(
            kind: .keywords,
            title: "Keywords",
            allowsFreeCreation: true
        ),
    ]

    static func polarityTitle(_ polarity: MailProjectConditionPolarity) -> String {
        polarity == .include ? "Include" : "Exclude"
    }
}

nonisolated struct ProjectKeywordValuePresentation: Equatable, Sendable {
    let value: String
    let badgeLabel: String

    var removeHelp: String { "Remove \(value)" }

    static func make(
        value: String,
        polarity: MailProjectConditionPolarity,
        keywordOperator: MailProjectKeywordOperator
    ) -> Self {
        let operatorLabel = switch keywordOperator {
        case .containsPhrase: "Phrase"
        case .anyWord: "Any"
        case .allWords: "All"
        }
        let requirementLabel = polarity == .include ? "Include" : "Exclude"
        return Self(
            value: value,
            badgeLabel: "\(requirementLabel) · \(operatorLabel)"
        )
    }
}

nonisolated struct ProjectCorrespondentSpecificCriteriaRow: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let detail: String
    let stableKeys: [String]
    let summary: String
}

nonisolated enum ProjectCorrespondentSpecificCriteriaPresentation {
    static func rows(
        catalogValues: [ProjectRuleValueOption],
        groups: [ProjectRuleGroupDraft],
        page: ProjectAutomaticCriteriaPage
    ) -> [ProjectCorrespondentSpecificCriteriaRow] {
        let catalogByKey = Dictionary(uniqueKeysWithValues: catalogValues.map { ($0.stableKey, $0) })
        let keys = Set(groups
            .filter { $0.kind == .match }
            .flatMap(\.conditions)
            .filter { $0.facet == .correspondent && $0.polarity == .include }
            .flatMap(\.values))

        return keys.map { key in
            let option = catalogByKey[key]
            let matchingGroups = groups.filter { group in
                    group.kind == .match && group.conditions.contains { condition in
                        condition.facet == .correspondent
                            && condition.polarity == .include
                            && condition.values.contains(key)
                    }
                }
            let summary = ProjectCriteriaSummary.text(
                for: conditionClusters(groups: matchingGroups, page: page).map(\.condition)
            )
            return ProjectCorrespondentSpecificCriteriaRow(
                id: key,
                displayName: option?.displayName ?? "Unavailable Correspondent",
                detail: option?.detail ?? key,
                stableKeys: [key],
                summary: summary.isEmpty ? "None" : summary
            )
        }
        .sorted { lhs, rhs in
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    static func conditionClusters(
        groups: [ProjectRuleGroupDraft],
        page: ProjectAutomaticCriteriaPage
    ) -> [ProjectCorrespondentConditionOccurrence] {
        let targets = groups.flatMap { group in
            group.conditions
                .filter { $0.facet != .correspondent && page.contains($0) }
                .map { ProjectCriteriaConditionTarget(group: group, condition: $0) }
        }
        return Dictionary(grouping: targets) {
            ProjectCriteriaConditionSemanticIdentity($0.condition)
        }
        .values
        .compactMap { targets in
            let orderedTargets = targets.sorted(by: targetOrder)
            guard let condition = orderedTargets.first?.condition else { return nil }
            return ProjectCorrespondentConditionOccurrence(
                condition: condition,
                targets: orderedTargets
            )
        }
        .sorted(by: occurrenceOrder)
    }

    nonisolated private static func targetOrder(
        _ lhs: ProjectCriteriaConditionTarget,
        _ rhs: ProjectCriteriaConditionTarget
    ) -> Bool {
        if lhs.group.sortIndex != rhs.group.sortIndex {
            return lhs.group.sortIndex < rhs.group.sortIndex
        }
        if lhs.condition.sortIndex != rhs.condition.sortIndex {
            return lhs.condition.sortIndex < rhs.condition.sortIndex
        }
        return lhs.id < rhs.id
    }

    nonisolated private static func occurrenceOrder(
        _ lhs: ProjectCorrespondentConditionOccurrence,
        _ rhs: ProjectCorrespondentConditionOccurrence
    ) -> Bool {
        if lhs.condition.sortIndex != rhs.condition.sortIndex {
            return lhs.condition.sortIndex < rhs.condition.sortIndex
        }
        return lhs.id < rhs.id
    }
}

nonisolated enum ProjectMessageCriteriaVisibleSection: Equatable, Sendable, Identifiable {
    case keywordFilterComposer
    case keywordFilters
    case criteriaFamily(ProjectMessageCriteriaSectionPresentation)
    case correspondentSpecific(title: String)

    var id: String {
        switch self {
        case .keywordFilterComposer: "keyword-filter-composer"
        case .keywordFilters: "keyword-filters"
        case .criteriaFamily(let section): "criteria-\(section.id)"
        case .correspondentSpecific(let title): "correspondents-\(title)"
        }
    }
}

nonisolated enum ProjectMessageCriteriaPresentation {
    static func visibleSections(
        for page: ProjectAutomaticCriteriaPage
    ) -> [ProjectMessageCriteriaVisibleSection] {
        if page == .keywords {
            return [
                .keywordFilterComposer,
                .keywordFilters,
                .correspondentSpecific(title: "Correspondent-Specific Keyword Filters"),
            ]
        }
        return page.sections.map(ProjectMessageCriteriaVisibleSection.criteriaFamily)
            + [.correspondentSpecific(title: "Correspondent-Specific \(page.title)")]
    }
}

enum ProjectCategoryMembershipChoice: CaseIterable, Equatable, Sendable {
    case include
    case exclude
}

enum ProjectCategoryCriteriaPresentation {
    static let title = "Categories"
    static let sourceSections = ProjectRuleValuePickerSection.categoryCases
    static let allowsFreeCreation = false

    static func contains(_ condition: ProjectRuleConditionDraft) -> Bool {
        sourceSections.contains { $0.facet == condition.facet }
    }
}

enum ProjectAutomaticCriteriaPage: Equatable, Sendable {
    case keywords
    case tags

    var sections: [ProjectMessageCriteriaSectionPresentation] {
        switch self {
        case .keywords:
            ProjectKeywordsCriteriaPresentation.sections
        case .tags:
            ProjectTagsCriteriaPresentation.sections
        }
    }

    var title: String {
        switch self {
        case .keywords: "Keywords"
        case .tags: "Tags"
        }
    }

    func contains(_ condition: ProjectRuleConditionDraft) -> Bool {
        sections.contains { $0.contains(condition) }
    }

    private static func categoricalSections(
        _ sections: [ProjectRuleValuePickerSection]
    ) -> [ProjectMessageCriteriaSectionPresentation] {
        sections.map {
            ProjectMessageCriteriaSectionPresentation(
                kind: .categorical($0),
                title: $0.title,
                allowsFreeCreation: false
            )
        }
    }
}

nonisolated struct ProjectCategoryOptionPresentation: Equatable, Sendable, Identifiable {
    let section: ProjectRuleValuePickerSection
    let option: ProjectRuleValueOption

    var id: String { "\(section.rawValue)|\(option.stableKey)" }
    var facet: MailProjectRuleFacet { section.facet }
    var symbolName: String {
        switch section {
        case .fixedCategories:
            MailPurpose(rawValue: option.stableKey)?.systemImageName
                ?? ToggleIconography.customCategorySymbolName
        case .customCategories:
            ToggleIconography.customCategorySymbolName
        default:
            ToggleIconography.customCategorySymbolName
        }
    }

    static func make(
        fixed: [ProjectRuleValueOption],
        custom: [ProjectRuleValueOption]
    ) -> [Self] {
        (fixed.map { Self(section: .fixedCategories, option: $0) }
            + custom.map { Self(section: .customCategories, option: $0) })
            .sorted { lhs, rhs in
                let order = lhs.option.displayName.localizedCaseInsensitiveCompare(
                    rhs.option.displayName
                )
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id < rhs.id
            }
    }
}

struct ProjectCategorySettingsView: View {
    @Bindable var state: ProjectConfigurationState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                projectWideCategories
                correspondentCategories
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var projectWideCategories: some View {
        OhiaSettingsCard("Categories") {
            SettingsBlock {
                Text("Include all mail from a category, exclude all mail from it, or leave it neutral. These choices apply across the project.")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
            if categoryOptions.isEmpty {
                SettingsRowDivider()
                SettingsCaption("No categories are available.")
            } else {
                ForEach(categoryOptions) { category in
                    SettingsRowDivider()
                    HStack(spacing: 12) {
                        Image(systemName: category.symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(OhiaColors.iconPillForeground)
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.option.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(OhiaColors.textPrimary)
                            Text(category.option.currentMatchCount == 1
                                ? "1 current message"
                                : "\(category.option.currentMatchCount) current messages")
                                .font(.caption)
                                .foregroundStyle(OhiaColors.textTertiary)
                        }
                        Spacer(minLength: 8)
                        categoryChoiceToggle(.include, category: category)
                        categoryChoiceToggle(.exclude, category: category)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    private var correspondentCategories: some View {
        OhiaSettingsCard("Correspondent Categories") {
            SettingsCaption("Each selected correspondent includes all categories by default. Use the pulldown beside a correspondent to narrow that person’s automatic paths.")
            if selectedCorrespondents.isEmpty {
                SettingsRowDivider()
                SettingsCaption("Select a correspondent before configuring correspondent-specific categories.")
            } else {
                ForEach(selectedCorrespondents) { row in
                    SettingsRowDivider()
                    ProjectCorrespondentCategoryRow(
                        state: state,
                        correspondent: row,
                        categories: categoryOptions
                    )
                }
            }
        }
    }

    private var categoryOptions: [ProjectCategoryOptionPresentation] {
        ProjectCategoryOptionPresentation.make(
            fixed: state.searchableValues(for: .fixedCategories, query: ""),
            custom: state.searchableValues(for: .customCategories, query: "")
        )
    }

    private var selectedCorrespondents: [ProjectCorrespondentRowPresentation] {
        let catalog = state.searchableValues(for: .correspondents, query: "")
        return ProjectCorrespondentPresentation.make(
            catalogValues: catalog,
            matchingCatalogValues: [],
            selectedPaths: correspondentPaths
        ).selectedRows
    }

    private var correspondentPaths: [ProjectCorrespondentSelectionPath] {
        (state.draft?.groups ?? []).filter { $0.kind == .match }.flatMap { group in
            group.conditions.compactMap { condition in
                guard condition.facet == .correspondent,
                      condition.polarity == .include,
                      condition.values.isEmpty == false else { return nil }
                return ProjectCorrespondentSelectionPath(
                    groupID: group.id,
                    conditionID: condition.id,
                    stableKeys: condition.values,
                    role: condition.correspondentRole ?? .involves
                )
            }
        }
    }

    private func categoryChoiceToggle(
        _ choice: ProjectCategoryMembershipChoice,
        category: ProjectCategoryOptionPresentation
    ) -> some View {
        Toggle(
            choice == .include ? "Include" : "Exclude",
            isOn: Binding(
                get: {
                    state.projectCategoryChoice(
                        stableKey: category.option.stableKey,
                        facet: category.facet
                    ) == choice
                },
                set: { isSelected in
                    state.setProjectCategory(
                        stableKey: category.option.stableKey,
                        facet: category.facet,
                        choice: isSelected ? choice : nil
                    )
                }
            )
        )
        .toggleStyle(.checkbox)
        .accessibilityLabel("\(choice == .include ? "Include" : "Exclude") all \(category.option.displayName) mail")
    }

}

private struct ProjectCorrespondentCategoryRow: View {
    @Bindable var state: ProjectConfigurationState
    let correspondent: ProjectCorrespondentRowPresentation
    let categories: [ProjectCategoryOptionPresentation]

    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(correspondent.option.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OhiaColors.textPrimary)
                if let detail = correspondent.option.detail,
                   detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "tag")
                        .font(.system(size: 10, weight: .semibold))
                    Text(selectionTitle)
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(OhiaColors.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(OhiaColors.iconPillBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(categories.isEmpty)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                MenuPopoverContent(
                    headerLabel: "Categories",
                    footer: "Checked categories may be included for this correspondent."
                ) {
                    ForEach(categories) { category in
                        MenuRow(
                            name: category.option.displayName,
                            symbolName: category.symbolName,
                            isChecked: isIncluded(category),
                            action: { setIncluded(!isIncluded(category), category: category) }
                        )
                    }
                }
            }
            .accessibilityLabel("Categories for \(correspondent.option.displayName)")
            .accessibilityValue(selectionTitle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var selectionTitle: String {
        guard categories.isEmpty == false else { return "No Categories" }
        let includedCount = categories.count(where: isIncluded)
        if includedCount == categories.count { return "All Categories" }
        if includedCount == 0 { return "No Categories" }
        return "\(includedCount) of \(categories.count) Categories"
    }

    private func isIncluded(_ category: ProjectCategoryOptionPresentation) -> Bool {
        correspondent.selectedStableKeys.allSatisfy { key in
            state.correspondentExcludedCategories(key)[category.facet]?
                .contains(category.option.stableKey) != true
        }
    }

    private func setIncluded(
        _ isIncluded: Bool,
        category: ProjectCategoryOptionPresentation
    ) {
        for stableKey in correspondent.selectedStableKeys {
            state.setCorrespondentCategory(
                stableKey,
                stableKey: category.option.stableKey,
                facet: category.facet,
                isIncluded: isIncluded
            )
        }
    }
}

enum ProjectMessageCriteriaPolicy {
    static func defaultPolarity(
        for groupKind: MailProjectRuleGroupKind
    ) -> MailProjectConditionPolarity {
        .include
    }
}

enum ProjectMessageCriteriaConditionRemovalIntent: Equatable, Sendable {
    case removeSharedCondition(conditionID: UUID)
    case removeCondition(groupID: UUID, conditionID: UUID)
}

enum ProjectMessageCriteriaRemovalPolicy {
    static func intent(
        for condition: ProjectRuleConditionDraft,
        in group: ProjectRuleGroupDraft?
    ) -> ProjectMessageCriteriaConditionRemovalIntent {
        guard let group else {
            return .removeSharedCondition(conditionID: condition.id)
        }
        return .removeCondition(groupID: group.id, conditionID: condition.id)
    }
}

struct ProjectKeywordScopeAccessibilityPresentation: Equatable, Sendable {
    let label: String
    let value: String
    let hint: String
    let isSelected: Bool

    static func make(
        scope: MailProjectKeywordScope,
        isSelected: Bool
    ) -> Self {
        let label = scope.projectMessageCriteriaTitle
        return Self(
            label: label,
            value: isSelected ? "Selected" : "Not selected",
            hint: "\(isSelected ? "Deselect" : "Select") \(label) keyword scope",
            isSelected: isSelected
        )
    }
}

enum ProjectCriteriaSummary {
    static func text(for groups: [ProjectRuleGroupDraft]) -> String {
        groups
            .sorted(by: groupOrder)
            .map { groupText($0) }
            .filter { $0.isEmpty == false }
            .joined(separator: " OR ")
    }

    static func text(for conditions: [ProjectRuleConditionDraft]) -> String {
        conditionText(conditions.sorted(by: conditionOrder))
    }

    private static func groupText(_ group: ProjectRuleGroupDraft) -> String {
        conditionText(group.conditions.sorted(by: conditionOrder))
    }

    private static func conditionText(_ conditions: [ProjectRuleConditionDraft]) -> String {
        conditions.enumerated().map { index, condition in
            let base = renderedCondition(condition)
            if index == 0 {
                return condition.polarity == .exclude ? "NOT \(base)" : base
            }
            return condition.polarity == .exclude ? "AND NOT \(base)" : "AND \(base)"
        }
        .joined(separator: " ")
    }

    private static func renderedCondition(_ condition: ProjectRuleConditionDraft) -> String {
        let values = Array(Set(condition.values)).sorted().joined(separator: ", ")
        if condition.facet.projectConfigurationIsKeyword {
            let operation = (condition.keywordOperator ?? .containsPhrase)
                .projectConfigurationTitle
            let scopes = MailProjectKeywordScope.allCases
                .filter(condition.keywordScopes.contains)
                .map(\.projectMessageCriteriaTitle)
                .joined(separator: " + ")
            return "\(scopes) Keywords · \(operation) · \(values)"
        }
        return "\(condition.facet.projectConfigurationTitle) · \(condition.quantifier.projectConfigurationTitle) · \(values)"
    }

    nonisolated private static func groupOrder(
        _ lhs: ProjectRuleGroupDraft,
        _ rhs: ProjectRuleGroupDraft
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    nonisolated private static func conditionOrder(
        _ lhs: ProjectRuleConditionDraft,
        _ rhs: ProjectRuleConditionDraft
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct ProjectMessageCriteriaView: View {
    @Bindable var state: ProjectConfigurationState
    let page: ProjectAutomaticCriteriaPage
    @State private var tagSearchQuery = ""
    @State private var loadingTagRecommendationFingerprint: ProjectTagRecommendationFingerprint?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if page == .tags {
                    tagSearch
                    tagMembership
                    relatedTags
                    correspondentSpecificCriteria(title: "Correspondent-Specific Tags")
                } else {
                    ForEach(ProjectMessageCriteriaPresentation.visibleSections(for: page)) { section in
                        sectionContent(section)
                    }
                }
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .task(id: page == .tags ? state.tagRecommendationFingerprint : nil) {
            guard page == .tags else { return }
            let fingerprint = state.tagRecommendationFingerprint
            loadingTagRecommendationFingerprint = fingerprint
            await state.refreshTagRecommendations()
            guard loadingTagRecommendationFingerprint == fingerprint else { return }
            loadingTagRecommendationFingerprint = nil
        }
    }

    private var tagSearch: some View {
        OhiaSettingsCard("Find Tags") {
            SettingsBlock {
                TextField("Search tags", text: $tagSearchQuery)
                    .textFieldStyle(.roundedBorder)
            }
            ForEach(tagSearchResults) { option in
                SettingsRowDivider()
                ProjectTagCatalogRow(
                    displayName: option.displayName,
                    detail: option.detail,
                    currentMatchCount: option.currentMatchCount,
                    isSelected: state.selectedSemanticTagKeys.contains(option.stableKey)
                ) {
                    state.addSharedSemanticTag(option.stableKey)
                }
            }
            if normalizedTagSearchQuery.isEmpty == false && tagSearchResults.isEmpty {
                SettingsRowDivider()
                SettingsCaption("No matching tags")
            }
        }
    }

    private var tagMembership: some View {
        OhiaSettingsCard("Tag Membership") {
            if sharedTagConditions.isEmpty {
                SettingsCaption("No tags selected")
            } else {
                ForEach(Array(sharedTagConditions.enumerated()), id: \.element.id) { index, condition in
                    if index > 0 { SettingsRowDivider() }
                    ProjectTagMembershipConditionEditor(
                        state: state,
                        condition: condition,
                        valuesByKey: tagValuesByKey
                    )
                }
            }
        }
    }

    private var relatedTags: some View {
        OhiaSettingsCard("Related Tags") {
            switch ProjectRelatedTagsPresentation.make(
                isLoading: isLoadingTagRecommendations,
                recommendationCount: state.tagRecommendations.count
            ) {
            case .loading:
                SettingsBlock {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding related tags")
                            .font(.caption)
                            .foregroundStyle(OhiaColors.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            case .empty:
                SettingsCaption("No related tags available")
            case .recommendations:
                ForEach(Array(state.tagRecommendations.enumerated()), id: \.element.id) { index, recommendation in
                    if index > 0 { SettingsRowDivider() }
                    ProjectTagCatalogRow(
                        displayName: recommendation.displayName,
                        detail: nil,
                        currentMatchCount: recommendation.currentMatchCount,
                        isSelected: false
                    ) {
                        state.addSharedSemanticTag(recommendation.tag.stableKey)
                    }
                }
            }
        }
    }

    private var isLoadingTagRecommendations: Bool {
        guard let loadingTagRecommendationFingerprint else { return false }
        return loadingTagRecommendationFingerprint == state.tagRecommendationFingerprint
    }

    private var normalizedTagSearchQuery: String {
        tagSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tagSearchResults: [ProjectRuleValueOption] {
        guard normalizedTagSearchQuery.isEmpty == false else { return [] }
        return Array(state.searchableValues(
            for: .semanticTags,
            query: normalizedTagSearchQuery
        ).prefix(12))
    }

    private var sharedTagConditions: [ProjectRuleConditionDraft] {
        sharedConditions.filter { $0.facet == .semanticTag }
    }

    private var tagValuesByKey: [String: ProjectRuleValueOption] {
        Dictionary(uniqueKeysWithValues: state.searchableValues(
            for: .semanticTags,
            query: ""
        ).map { ($0.stableKey, $0) })
    }

    @ViewBuilder
    private func sectionContent(
        _ section: ProjectMessageCriteriaVisibleSection
    ) -> some View {
        switch section {
        case .keywordFilterComposer:
            ProjectSharedKeywordFilterComposer(
                state: state,
                sortIndex: sharedConditions.count
            )
        case .keywordFilters:
            ProjectSharedKeywordFiltersCard(
                state: state,
                conditions: sharedConditions.filter(
                    ProjectKeywordsCriteriaPresentation.sections[0].contains
                )
            )
        case .criteriaFamily(let family):
            ProjectSharedCriteriaFamilyCard(
                state: state,
                section: family,
                conditions: sharedConditions.filter(family.contains)
            )
        case .correspondentSpecific(let title):
            correspondentSpecificCriteria(title: title)
        }
    }

    private func correspondentSpecificCriteria(title: String) -> some View {
        OhiaSettingsCard(title) {
            SettingsCaption("Expand a correspondent to add or review criteria that narrow only that correspondent's automatic mail.")
            if selectedCorrespondentRows.isEmpty {
                SettingsRowDivider()
                SettingsCaption("Select a correspondent first to configure correspondent-specific \(page.title.lowercased()).")
            } else {
                ForEach(selectedCorrespondentRows) { row in
                    SettingsRowDivider()
                    ProjectCorrespondentCriteriaDisclosure(
                        state: state,
                        row: row,
                        groups: groups(for: row),
                        page: page
                    )
                }
            }
        }
    }

    private var sharedConditions: [ProjectRuleConditionDraft] {
        (state.draft?.groups ?? [])
            .filter { $0.kind == .sharedCriteria }
            .flatMap(\.conditions)
            .sorted(by: ProjectMessageCriteriaView.conditionOrder)
    }

    private var selectedCorrespondentRows: [ProjectCorrespondentSpecificCriteriaRow] {
        ProjectCorrespondentSpecificCriteriaPresentation.rows(
            catalogValues: state.searchableValues(for: .correspondents, query: ""),
            groups: state.draft?.groups ?? [],
            page: page
        )
    }

    private func groups(
        for row: ProjectCorrespondentSpecificCriteriaRow
    ) -> [ProjectRuleGroupDraft] {
        let keys = Set(row.stableKeys)
        return (state.draft?.groups ?? [])
            .filter { group in
                group.kind == .match && group.conditions.contains { condition in
                    condition.facet == .correspondent
                        && condition.polarity == .include
                        && keys.isDisjoint(with: condition.values) == false
                }
            }
            .sorted(by: Self.groupOrder)
    }

    nonisolated private static func groupOrder(
        _ lhs: ProjectRuleGroupDraft,
        _ rhs: ProjectRuleGroupDraft
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    nonisolated private static func conditionOrder(
        _ lhs: ProjectRuleConditionDraft,
        _ rhs: ProjectRuleConditionDraft
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct ProjectTagCatalogRow: View {
    let displayName: String
    let detail: String?
    let currentMatchCount: Int
    let isSelected: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                if let detail,
                   detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
                Text(currentMatchCount == 1
                    ? "1 current message"
                    : "\(currentMatchCount) current messages")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            Spacer(minLength: 8)
            Button {
                onAdd()
            } label: {
                Label(
                    isSelected ? "Added" : "Add",
                    systemImage: isSelected ? "checkmark" : "plus"
                )
            }
                .buttonStyle(.emblem)
                .disabled(isSelected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct ProjectTagMembershipConditionEditor: View {
    @Bindable var state: ProjectConfigurationState
    let condition: ProjectRuleConditionDraft
    let valuesByKey: [String: ProjectRuleValueOption]

    var body: some View {
        SettingsBlock {
            HStack(spacing: 8) {
                Picker("Include or Exclude", selection: polarityBinding) {
                    Text("Include").tag(MailProjectConditionPolarity.include)
                    Text("Exclude").tag(MailProjectConditionPolarity.exclude)
                }
                .labelsHidden()
                .frame(width: 105)
                Picker("Any or All", selection: quantifierBinding) {
                    Text("Any").tag(MailProjectValueQuantifier.any)
                    Text("All").tag(MailProjectValueQuantifier.all)
                }
                .labelsHidden()
                .frame(width: 75)
                Spacer(minLength: 8)
                Button("Remove", systemImage: "trash") {
                    state.removeSharedCondition(condition.id)
                }
                .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
            }

            WrappingChipStack(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(Set(condition.values)).sorted(), id: \.self) { value in
                    ProjectKeywordValueChip(
                        presentation: ProjectKeywordValuePresentation(
                            value: value,
                            badgeLabel: "\(condition.polarity == .include ? "Include" : "Exclude") · \(condition.quantifier == .any ? "Any" : "All")"
                        ),
                        displayValue: valuesByKey[value]?.displayName ?? value,
                        polarity: condition.polarity
                    ) {
                        remove(value)
                    }
                }
            }
        }
    }

    private var polarityBinding: Binding<MailProjectConditionPolarity> {
        Binding(
            get: { condition.polarity },
            set: { value in update { $0.polarity = value } }
        )
    }

    private var quantifierBinding: Binding<MailProjectValueQuantifier> {
        Binding(
            get: { condition.quantifier },
            set: { value in update { $0.quantifier = value } }
        )
    }

    private func remove(_ value: String) {
        var updated = condition
        updated.values.removeAll { $0 == value }
        if updated.values.isEmpty {
            state.removeSharedCondition(condition.id)
        } else {
            state.upsertSharedCondition(updated)
        }
    }

    private func update(_ mutation: (inout ProjectRuleConditionDraft) -> Void) {
        var updated = condition
        mutation(&updated)
        state.upsertSharedCondition(updated)
    }
}

nonisolated struct ProjectCriteriaConditionTarget: Equatable, Sendable, Identifiable {
    let group: ProjectRuleGroupDraft
    let condition: ProjectRuleConditionDraft

    var id: String { "\(group.id.uuidString)-\(condition.id.uuidString)" }
}

nonisolated struct ProjectCorrespondentConditionOccurrence: Equatable, Sendable, Identifiable {
    let condition: ProjectRuleConditionDraft
    let targets: [ProjectCriteriaConditionTarget]

    var id: String { targets.map(\.id).sorted().joined(separator: "|") }
}

nonisolated private struct ProjectCriteriaConditionSemanticIdentity: Hashable, Sendable {
    let facet: String
    let polarity: String
    let quantifier: String
    let values: [String]
    let keywordScopes: [String]
    let keywordOperator: String?

    init(_ condition: ProjectRuleConditionDraft) {
        facet = condition.facet.rawValue
        polarity = condition.polarity.rawValue
        quantifier = condition.quantifier.rawValue
        values = Array(Set(condition.values)).sorted()
        keywordScopes = condition.keywordScopes.map(\.rawValue).sorted()
        keywordOperator = condition.keywordOperator?.rawValue
    }
}

private struct ProjectCorrespondentCriteriaDisclosure: View {
    @Bindable var state: ProjectConfigurationState
    let row: ProjectCorrespondentSpecificCriteriaRow
    let groups: [ProjectRuleGroupDraft]
    let page: ProjectAutomaticCriteriaPage

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OhiaColors.textPrimary)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(OhiaColors.textSecondary)
                    }
                    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

                    Text(row.summary)
                        .font(.caption)
                        .foregroundStyle(row.summary == "None"
                            ? OhiaColors.textTertiary
                            : OhiaColors.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 330, alignment: .trailing)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.displayName), \(row.detail)")
            .accessibilityValue(row.summary)
            .accessibilityHint(
                isExpanded
                    ? "Collapse \(page.title.lowercased()) settings"
                    : "Expand \(page.title.lowercased()) settings"
            )

            if isExpanded {
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 12) {
                    if occurrences.isEmpty {
                        SettingsCaption("No correspondent-specific \(page.title.lowercased()) are configured.")
                    } else {
                        ForEach(occurrences) { occurrence in
                            ProjectCriteriaConditionEditor(
                                state: state,
                                condition: occurrence.condition,
                                group: occurrence.targets.first?.group,
                                synchronizedTargets: occurrence.targets
                            )
                        }
                    }

                    ProjectCorrespondentNewCriteriaEditor(
                        state: state,
                        row: row,
                        page: page
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var occurrences: [ProjectCorrespondentConditionOccurrence] {
        ProjectCorrespondentSpecificCriteriaPresentation.conditionClusters(
            groups: groups,
            page: page
        )
    }
}

private struct ProjectCorrespondentNewCriteriaEditor: View {
    @Bindable var state: ProjectConfigurationState
    let row: ProjectCorrespondentSpecificCriteriaRow
    let page: ProjectAutomaticCriteriaPage

    @State private var pickerTarget: SharedCriteriaPickerTarget?
    @State private var keywordDraft = ""
    @State private var keywordPolarity: MailProjectConditionPolarity = .include
    @State private var keywordOperator: MailProjectKeywordOperator = .containsPhrase
    @State private var keywordScopes: Set<MailProjectKeywordScope> = [.subject, .body]

    var body: some View {
        SettingsBlock {
            switch page {
            case .keywords:
                keywordEditor
            default:
                Menu {
                    ForEach(page.sections) { section in
                        if case .categorical(let pickerSection) = section.kind {
                            Button(section.title, systemImage: "plus.circle") {
                                pickerTarget = SharedCriteriaPickerTarget(section: pickerSection)
                            }
                        }
                    }
                } label: {
                    Label("Add \(page.title)", systemImage: "plus")
                }
                .buttonStyle(.emblem)
            }
        }
        .sheet(item: $pickerTarget) { target in
            ProjectRuleValuePicker(
                state: state,
                section: target.section,
                initialSelection: [],
                onApply: { selection in
                    guard selection.isEmpty == false else { return }
                    state.addCorrespondentSpecificCondition(
                        ProjectRuleConditionDraft(
                            facet: target.section.facet,
                            values: Array(selection).sorted(),
                            sortIndex: 1
                        ),
                        correspondentKeys: Set(row.stableKeys)
                    )
                    pickerTarget = nil
                },
                onCancel: { pickerTarget = nil }
            )
        }
    }

    private var keywordEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Keyword or phrase", text: $keywordDraft)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Picker("Keyword Operator", selection: $keywordOperator) {
                    ForEach(MailProjectKeywordOperator.allCases, id: \.self) { operation in
                        Text(operation.projectConfigurationTitle).tag(operation)
                    }
                }
                Picker("Requirement", selection: $keywordPolarity) {
                    ForEach(ProjectKeywordsCriteriaPresentation.polarities, id: \.self) { polarity in
                        Text(ProjectKeywordsCriteriaPresentation.polarityTitle(polarity))
                            .tag(polarity)
                    }
                }
            }
            keywordScopeControls
            Button("Add Keyword", systemImage: "plus") {
                addKeyword()
            }
            .buttonStyle(.emblem)
            .disabled(trimmedKeyword.isEmpty || keywordScopes.isEmpty)
        }
    }

    private var keywordScopeControls: some View {
        HStack(spacing: 6) {
            Text("Search in")
                .font(.caption)
                .foregroundStyle(OhiaColors.textSecondary)
            ForEach(ProjectKeywordsCriteriaPresentation.scopes, id: \.self) { scope in
                let isSelected = keywordScopes.contains(scope)
                Button {
                    if isSelected {
                        keywordScopes.remove(scope)
                    } else {
                        keywordScopes.insert(scope)
                    }
                } label: {
                    FilterChipLabel(
                        text: scope.projectMessageCriteriaTitle,
                        systemImage: isSelected ? "checkmark" : "magnifyingglass",
                        isOn: isSelected
                    )
                }
                .buttonStyle(.plain)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private var trimmedKeyword: String {
        keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addKeyword() {
        guard trimmedKeyword.isEmpty == false, keywordScopes.isEmpty == false else { return }
        state.addCorrespondentSpecificCondition(
            ProjectRuleConditionDraft(
                facet: .subject,
                polarity: keywordPolarity,
                values: [trimmedKeyword],
                keywordScopes: keywordScopes,
                keywordOperator: keywordOperator,
                sortIndex: 1
            ),
            correspondentKeys: Set(row.stableKeys)
        )
        keywordDraft = ""
    }
}

private struct ProjectSharedKeywordFilterComposer: View {
    @Bindable var state: ProjectConfigurationState
    let sortIndex: Int

    @State private var keywordDraft = ""
    @State private var keywordPolarity: MailProjectConditionPolarity = .include
    @State private var keywordOperator: MailProjectKeywordOperator = .containsPhrase
    @State private var keywordScopes: Set<MailProjectKeywordScope> = [.subject, .body]

    var body: some View {
        OhiaSettingsCard("Create Keyword Filter") {
            SettingsCaption("Configure a keyword filter, then add it to the project.")
            SettingsRowDivider()
            SettingsBlock {
                HStack(spacing: 8) {
                    Text("Requirement")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OhiaColors.textPrimary)
                    Spacer(minLength: 8)
                    ForEach(ProjectKeywordsCriteriaPresentation.polarities, id: \.self) { polarity in
                        let isSelected = keywordPolarity == polarity
                        let title = ProjectKeywordsCriteriaPresentation.polarityTitle(polarity)
                        Button {
                            keywordPolarity = polarity
                        } label: {
                            FilterChipLabel(
                                text: title,
                                systemImage: isSelected
                                    ? "checkmark"
                                    : (polarity == .include ? "plus" : "minus"),
                                isOn: isSelected
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title)
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }

                HStack(spacing: 8) {
                    Picker("Keyword Operator", selection: $keywordOperator) {
                        ForEach(MailProjectKeywordOperator.allCases, id: \.self) { operation in
                            Text(operation.projectConfigurationTitle).tag(operation)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    TextField("Keyword or phrase", text: $keywordDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Add Filter", systemImage: "plus") {
                        addKeywordFilter()
                    }
                    .buttonStyle(.emblem)
                    .disabled(trimmedKeyword.isEmpty || keywordScopes.isEmpty)
                }

                keywordScopeControls
            }
        }
    }

    private var keywordScopeControls: some View {
        HStack(spacing: 6) {
            Text("Search in")
                .font(.caption)
                .foregroundStyle(OhiaColors.textSecondary)
            ForEach(ProjectKeywordsCriteriaPresentation.scopes, id: \.self) { scope in
                let isSelected = keywordScopes.contains(scope)
                let accessibility = ProjectKeywordScopeAccessibilityPresentation.make(
                    scope: scope,
                    isSelected: isSelected
                )
                Button {
                    if isSelected {
                        keywordScopes.remove(scope)
                    } else {
                        keywordScopes.insert(scope)
                    }
                } label: {
                    FilterChipLabel(
                        text: scope.projectMessageCriteriaTitle,
                        systemImage: isSelected ? "checkmark" : "magnifyingglass",
                        isOn: isSelected
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibility.label)
                .accessibilityValue(accessibility.value)
                .accessibilityHint(accessibility.hint)
                .accessibilityAddTraits(accessibility.isSelected ? [.isSelected] : [])
            }
        }
    }

    private var trimmedKeyword: String {
        keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addKeywordFilter() {
        guard trimmedKeyword.isEmpty == false, keywordScopes.isEmpty == false else { return }
        state.upsertSharedCondition(ProjectRuleConditionDraft(
            facet: .subject,
            polarity: keywordPolarity,
            quantifier: .any,
            values: [trimmedKeyword],
            keywordScopes: keywordScopes,
            keywordOperator: keywordOperator,
            sortIndex: sortIndex
        ))
        keywordDraft = ""
    }
}

private struct ProjectSharedKeywordFiltersCard: View {
    @Bindable var state: ProjectConfigurationState
    let conditions: [ProjectRuleConditionDraft]

    var body: some View {
        OhiaSettingsCard("Keyword Filters") {
            SettingsCaption("Applied only to mail matched by included correspondents, lists, and categories. Manually added threads and messages are not filtered.")
            if conditions.isEmpty {
                SettingsRowDivider()
                SettingsCaption("No keyword filters have been added.")
            } else {
                ForEach(conditions) { condition in
                    SettingsRowDivider()
                    ProjectCriteriaConditionEditor(
                        state: state,
                        condition: condition,
                        group: nil
                    )
                }
            }
        }
    }
}

private struct ProjectSharedCriteriaFamilyCard: View {
    @Bindable var state: ProjectConfigurationState
    let section: ProjectMessageCriteriaSectionPresentation
    let conditions: [ProjectRuleConditionDraft]

    @State private var pickerTarget: SharedCriteriaPickerTarget?

    var body: some View {
        OhiaSettingsCard(section.title) {
            if conditions.isEmpty {
                emptyEditor
            } else {
                ForEach(Array(conditions.enumerated()), id: \.element.id) { index, condition in
                    if index > 0 { SettingsRowDivider() }
                    ProjectCriteriaConditionEditor(
                        state: state,
                        condition: condition,
                        group: nil
                    )
                }
            }
        }
        .sheet(item: $pickerTarget) { target in
            ProjectRuleValuePicker(
                state: state,
                section: target.section,
                initialSelection: [],
                onApply: { selection in
                    guard selection.isEmpty == false else { return }
                    state.upsertSharedCondition(ProjectRuleConditionDraft(
                        facet: target.section.facet,
                        values: Array(selection),
                        sortIndex: sharedConditionCount
                    ))
                    pickerTarget = nil
                },
                onCancel: { pickerTarget = nil }
            )
        }
    }

    @ViewBuilder
    private var emptyEditor: some View {
        if case .categorical(let pickerSection) = section.kind {
            SettingsBlock {
                Text("Search the existing \(section.title.lowercased()) catalog. New values cannot be created here.")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
                Button("Search Values", systemImage: "magnifyingglass") {
                    pickerTarget = SharedCriteriaPickerTarget(section: pickerSection)
                }
                .buttonStyle(.emblem)
            }
        }
    }

    private var sharedConditionCount: Int {
        (state.draft?.groups ?? [])
            .filter { $0.kind == .sharedCriteria }
            .flatMap(\.conditions)
            .count
    }
}

private struct SharedCriteriaPickerTarget: Identifiable {
    let section: ProjectRuleValuePickerSection
    var id: String { section.id }
}

private struct ProjectCriteriaConditionEditor: View {
    @Bindable var state: ProjectConfigurationState
    let condition: ProjectRuleConditionDraft
    let group: ProjectRuleGroupDraft?
    var synchronizedTargets: [ProjectCriteriaConditionTarget] = []

    @State private var pickerTarget: ConditionPickerTarget?
    @State private var keywordDraft = ""

    var body: some View {
        SettingsBlock {
            HStack(spacing: 8) {
                Text(condition.facet.projectConfigurationTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                Spacer(minLength: 8)
                Picker(
                    condition.facet.projectConfigurationIsKeyword
                        ? "Keyword Requirement"
                        : "Include or Exclude",
                    selection: polarityBinding
                ) {
                    Text(polarityTitle(.include)).tag(MailProjectConditionPolarity.include)
                    Text(polarityTitle(.exclude)).tag(MailProjectConditionPolarity.exclude)
                }
                .labelsHidden()
                .frame(width: condition.facet.projectConfigurationIsKeyword ? 125 : 105)
                Picker("Any or All", selection: quantifierBinding) {
                    Text("Any").tag(MailProjectValueQuantifier.any)
                    Text("All").tag(MailProjectValueQuantifier.all)
                }
                .labelsHidden()
                .frame(width: 75)
                Button("Remove", systemImage: "trash") {
                    removeCondition()
                }
                .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
            }

            if condition.facet.projectConfigurationIsKeyword {
                keywordEditor
            } else if let section = pickerSection {
                Button(
                    condition.values.isEmpty ? "Search Values" : "Edit Values",
                    systemImage: condition.values.isEmpty ? "magnifyingglass" : "pencil"
                ) {
                    pickerTarget = ConditionPickerTarget(section: section)
                }
                .buttonStyle(.emblem)
                selectedValueButtons
            }

            validationIssues
        }
        .sheet(item: $pickerTarget) { target in
            ProjectRuleValuePicker(
                state: state,
                section: target.section,
                initialSelection: Set(condition.values),
                onApply: { selection in
                    updateCondition { $0.values = Array(selection).sorted() }
                    pickerTarget = nil
                },
                onCancel: { pickerTarget = nil }
            )
        }
    }

    private var keywordEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Keyword Operator", selection: keywordOperatorBinding) {
                    ForEach(MailProjectKeywordOperator.allCases, id: \.self) { operation in
                        Text(operation.projectConfigurationTitle).tag(operation)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                TextField("Keyword or phrase", text: $keywordDraft)
                    .textFieldStyle(.roundedBorder)
                Button(
                    ProjectKeywordsCriteriaPresentation.addTermTitle,
                    systemImage: "plus"
                ) {
                    addKeyword()
                }
                .buttonStyle(.emblem)
                .disabled(trimmedKeyword.isEmpty)
            }
            HStack(spacing: 6) {
                Text("Search in")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
                ForEach(ProjectKeywordsCriteriaPresentation.scopes, id: \.self) { scope in
                    let isSelected = condition.keywordScopes.contains(scope)
                    let accessibility = ProjectKeywordScopeAccessibilityPresentation.make(
                        scope: scope,
                        isSelected: isSelected
                    )
                    Button {
                        updateCondition {
                            if $0.keywordScopes.contains(scope) {
                                $0.keywordScopes.remove(scope)
                            } else {
                                $0.keywordScopes.insert(scope)
                            }
                        }
                    } label: {
                        FilterChipLabel(
                            text: scope.projectMessageCriteriaTitle,
                            systemImage: isSelected ? "checkmark" : "magnifyingglass",
                            isOn: isSelected
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibility.label)
                    .accessibilityValue(accessibility.value)
                    .accessibilityHint(accessibility.hint)
                    .accessibilityAddTraits(accessibility.isSelected ? [.isSelected] : [])
                }
            }
            selectedValueButtons
        }
    }

    @ViewBuilder
    private var selectedValueButtons: some View {
        if condition.values.isEmpty {
            Text("No values selected")
                .font(.caption)
                .foregroundStyle(OhiaColors.textTertiary)
        } else {
            let keywordOperator = condition.keywordOperator ?? .containsPhrase
            let values = Array(Set(condition.values)).sorted().map {
                ProjectKeywordValuePresentation.make(
                    value: $0,
                    polarity: condition.polarity,
                    keywordOperator: keywordOperator
                )
            }
            WrappingChipStack(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(values, id: \.value) { presentation in
                    ProjectKeywordValueChip(
                        presentation: presentation,
                        displayValue: displayName(for: presentation.value),
                        polarity: condition.polarity
                    ) {
                        updateCondition {
                            $0.values.removeAll { $0 == presentation.value }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var validationIssues: some View {
        let synchronizedGroupIDs = Set(synchronizedTargets.map { $0.group.id })
        let issues = state.validationReport?.issues.filter {
            guard $0.conditionID == condition.id else { return false }
            if synchronizedGroupIDs.isEmpty == false {
                return synchronizedGroupIDs.contains($0.groupID)
            }
            return group == nil || $0.groupID == group?.id
        } ?? []
        ForEach(issues) { issue in
            Text(issue.code.projectConfigurationCopy)
                .font(.caption)
                .foregroundStyle(OhiaColors.ohiaRed)
        }
    }

    private var pickerSection: ProjectRuleValuePickerSection? {
        ProjectRuleValuePickerSection.allCases.first { $0.facet == condition.facet }
    }

    private var trimmedKeyword: String {
        keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func polarityTitle(_ polarity: MailProjectConditionPolarity) -> String {
        if condition.facet.projectConfigurationIsKeyword {
            return ProjectKeywordsCriteriaPresentation.polarityTitle(polarity)
        }
        return polarity == .include ? "Include" : "Exclude"
    }

    private var polarityBinding: Binding<MailProjectConditionPolarity> {
        Binding(
            get: { condition.polarity },
            set: { value in updateCondition { $0.polarity = value } }
        )
    }

    private var quantifierBinding: Binding<MailProjectValueQuantifier> {
        Binding(
            get: { condition.quantifier },
            set: { value in updateCondition { $0.quantifier = value } }
        )
    }

    private var keywordOperatorBinding: Binding<MailProjectKeywordOperator> {
        Binding(
            get: { condition.keywordOperator ?? .containsPhrase },
            set: { value in updateCondition { $0.keywordOperator = value } }
        )
    }

    private func addKeyword() {
        guard trimmedKeyword.isEmpty == false else { return }
        updateCondition {
            $0.values = Array(Set($0.values + [trimmedKeyword])).sorted()
        }
        keywordDraft = ""
    }

    private func displayName(for value: String) -> String {
        guard let pickerSection else { return value }
        return state.searchableValues(for: pickerSection, query: "")
            .first { $0.stableKey == value }?.displayName ?? value
    }

    private func updateCondition(
        _ mutation: (inout ProjectRuleConditionDraft) -> Void
    ) {
        if synchronizedTargets.isEmpty == false {
            for target in synchronizedTargets {
                var updated = target.condition
                mutation(&updated)
                state.updateCondition(updated, in: target.group.id)
            }
            return
        }
        var updated = condition
        mutation(&updated)
        if let group {
            state.updateCondition(updated, in: group.id)
        } else {
            state.upsertSharedCondition(updated)
        }
    }

    private func removeCondition() {
        if synchronizedTargets.isEmpty == false {
            for target in synchronizedTargets {
                state.removeCondition(target.condition.id, from: target.group.id)
            }
            return
        }
        switch ProjectMessageCriteriaRemovalPolicy.intent(for: condition, in: group) {
        case .removeSharedCondition(let conditionID):
            state.removeSharedCondition(conditionID)
        case .removeCondition(let groupID, let conditionID):
            state.removeCondition(conditionID, from: groupID)
        }
    }
}

private struct ProjectKeywordValueChip: View {
    let presentation: ProjectKeywordValuePresentation
    let displayValue: String
    let polarity: MailProjectConditionPolarity
    let onRemove: () -> Void

    @State private var isDeleteHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        isDeleteHovered
                            ? OhiaColors.ohiaRed
                            : OhiaColors.ohiaGreen
                    )
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(presentation.removeHelp)
            .accessibilityLabel(presentation.removeHelp)
            .onHover { isDeleteHovered = $0 }

            Text(presentation.badgeLabel.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(OhiaColors.chipActiveBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            OhiaColors.chipActiveBorder,
                            lineWidth: 1
                        )
                }

            Text(displayValue)
                .foregroundStyle(
                    polarity == .exclude
                        ? OhiaColors.ohiaRed
                        : OhiaColors.ohiaGreen
                )
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 2)
        .padding(.trailing, 12)
        .padding(.vertical, 1)
        .background(OhiaColors.buttonBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension MailProjectKeywordScope {
    var projectMessageCriteriaTitle: String {
        switch self {
        case .attachmentFilename:
            "Attachment Name"
        default:
            projectConfigurationTitle
        }
    }
}

private struct ConditionPickerTarget: Identifiable {
    let section: ProjectRuleValuePickerSection
    var id: String { section.id }
}
