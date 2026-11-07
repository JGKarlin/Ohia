import SwiftUI
import OhiaCore
import OhiaML

nonisolated struct ProjectCorrespondentSearchFingerprint: Equatable, Sendable {
    let query: String
    let catalogValues: [ProjectRuleValueOption]

    var showsResults: Bool { query.isEmpty == false }
}

nonisolated struct ProjectCorrespondentSelectionPath: Equatable, Sendable {
    let groupID: UUID
    let conditionID: UUID
    let stableKeys: [String]
    let role: MailProjectCorrespondentRole
}

nonisolated enum ProjectCorrespondentSelectionMutation: Equatable, Sendable {
    case select(stableKey: String, roles: Set<MailProjectCorrespondentRole>)
    case deselect(stableKeys: [String])
}

nonisolated struct ProjectCorrespondentRoleSelectionMutation: Equatable, Sendable {
    let stableKeys: [String]
    let roles: Set<MailProjectCorrespondentRole>
}

nonisolated enum ProjectCorrespondentRolePresentation {
    static let roles: [MailProjectCorrespondentRole] = [.from, .to, .cc, .bcc]
    static let defaultRoles: Set<MailProjectCorrespondentRole> = Set(roles)
}

nonisolated struct ProjectCorrespondentRowPresentation: Equatable, Sendable, Identifiable {
    let id: String
    let option: ProjectRuleValueOption
    let selectedStableKeys: [String]
    let selectedPaths: [ProjectCorrespondentSelectionPath]

    var isSelected: Bool { selectedStableKeys.isEmpty == false }
    var selectedRoles: Set<MailProjectCorrespondentRole> {
        selectedPaths.reduce(into: []) { result, path in
            if path.role == .involves {
                result.formUnion(ProjectCorrespondentRolePresentation.defaultRoles)
            } else {
                result.insert(path.role)
            }
        }
    }

    var selectionMutation: ProjectCorrespondentSelectionMutation {
        if isSelected {
            return .deselect(stableKeys: selectedStableKeys)
        }
        return .select(
            stableKey: option.stableKey,
            roles: ProjectCorrespondentRolePresentation.defaultRoles
        )
    }

    func roleSelectionMutation(
        role: MailProjectCorrespondentRole,
        isSelected: Bool
    ) -> ProjectCorrespondentRoleSelectionMutation {
        var roles = selectedRoles
        if isSelected { roles.insert(role) } else { roles.remove(role) }
        return ProjectCorrespondentRoleSelectionMutation(
            stableKeys: selectedStableKeys,
            roles: roles
        )
    }
}

nonisolated struct ProjectCorrespondentPresentation: Equatable, Sendable {
    let selectedRows: [ProjectCorrespondentRowPresentation]
    let resultRows: [ProjectCorrespondentRowPresentation]

    static func make(
        catalogValues: [ProjectRuleValueOption],
        matchingCatalogValues: [ProjectRuleValueOption],
        selectedPaths: [ProjectCorrespondentSelectionPath]
    ) -> Self {
        let optionByStableKey = catalogValues.reduce(into: [:]) { result, option in
            result[option.stableKey] = option
        }

        func logicalStableKey(for stableKey: String) -> String {
            optionByStableKey[stableKey]?.canonicalStableKey ?? stableKey
        }

        var selectedPathsByLogicalKey: [String: [ProjectCorrespondentSelectionPath]] = [:]
        var selectedStableKeysByLogicalKey: [String: Set<String>] = [:]
        for path in selectedPaths {
            var logicalKeysInPath: Set<String> = []
            for stableKey in path.stableKeys {
                let logicalKey = logicalStableKey(for: stableKey)
                selectedStableKeysByLogicalKey[logicalKey, default: []].insert(stableKey)
                logicalKeysInPath.insert(logicalKey)
            }
            for logicalKey in logicalKeysInPath {
                selectedPathsByLogicalKey[logicalKey, default: []].append(path)
            }
        }

        func row(for logicalKey: String) -> ProjectCorrespondentRowPresentation {
            let selectedStableKeys = selectedStableKeysByLogicalKey[logicalKey, default: []]
                .sorted()
            let fallbackKey = selectedStableKeys.first ?? logicalKey
            let option = optionByStableKey[logicalKey]
                ?? optionByStableKey[fallbackKey]
                ?? ProjectRuleValueOption(
                    stableKey: logicalKey,
                    displayName: "Unavailable Correspondent",
                    detail: logicalKey,
                    currentMatchCount: 0,
                    isValid: false
                )
            let paths = selectedPathsByLogicalKey[logicalKey, default: []]
                .sorted { lhs, rhs in
                    if lhs.groupID != rhs.groupID {
                        return lhs.groupID.uuidString < rhs.groupID.uuidString
                    }
                    return lhs.conditionID.uuidString < rhs.conditionID.uuidString
                }
            return ProjectCorrespondentRowPresentation(
                id: logicalKey,
                option: option,
                selectedStableKeys: selectedStableKeys,
                selectedPaths: paths
            )
        }

        let selectedRows = selectedStableKeysByLogicalKey.keys
            .map(row(for:))
            .sorted(by: rowOrder)

        var seenResultKeys: Set<String> = []
        let resultRows: [ProjectCorrespondentRowPresentation] = matchingCatalogValues.compactMap { option in
            let logicalKey = logicalStableKey(for: option.stableKey)
            guard seenResultKeys.insert(logicalKey).inserted else { return nil }
            return row(for: logicalKey)
        }

        return Self(selectedRows: selectedRows, resultRows: resultRows)
    }

    private static func rowOrder(
        _ lhs: ProjectCorrespondentRowPresentation,
        _ rhs: ProjectCorrespondentRowPresentation
    ) -> Bool {
        let displayOrder = lhs.option.displayName.localizedCaseInsensitiveCompare(
            rhs.option.displayName
        )
        if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
        return lhs.id < rhs.id
    }
}

struct ProjectCorrespondentsEditorView: View {
    @Bindable var state: ProjectConfigurationState

    @State private var query = ""
    @State private var searchResults: [ProjectRuleValueOption] = []
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        let catalogValues = state.searchableValues(for: .correspondents, query: "")
        let presentation = ProjectCorrespondentPresentation.make(
            catalogValues: catalogValues,
            matchingCatalogValues: searchResults,
            selectedPaths: selectedPaths
        )

        LazyVStack(alignment: .leading, spacing: 18) {
            searchCard
            selectedCard(presentation.selectedRows)
            if normalizedQuery.isEmpty == false {
                resultsCard(presentation.resultRows)
            }
        }
        .onChange(
            of: ProjectCorrespondentSearchFingerprint(
                query: normalizedQuery,
                catalogValues: catalogValues
            ),
            initial: true
        ) { _, fingerprint in
            guard fingerprint.showsResults else {
                searchResults = []
                return
            }
            searchResults = state.searchableValues(
                for: .correspondents,
                query: fingerprint.query
            )
        }
        .onAppear { searchIsFocused = true }
    }

    private var searchCard: some View {
        OhiaSettingsCard("Correspondents") {
            SettingsBlock {
                TextField("Search by name or email address", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchIsFocused)
                    .accessibilityLabel("Search correspondents by name or email address")

                Text("Select people or addresses whose mail may be included automatically. New correspondents include From, To, Cc, and Bcc mail by default.")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
        }
    }

    private func selectedCard(
        _ rows: [ProjectCorrespondentRowPresentation]
    ) -> some View {
        OhiaSettingsCard("Selected Correspondents") {
            if rows.isEmpty {
                SettingsCaption("No correspondents selected.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        selectionRow(row)
                    }
                }
            }
        }
    }

    private func resultsCard(
        _ rows: [ProjectCorrespondentRowPresentation]
    ) -> some View {
        OhiaSettingsCard("Search Results") {
            if rows.isEmpty {
                SettingsCaption("No correspondents match this search.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        selectionRow(row)
                    }
                }
            }
        }
    }

    private func selectionRow(
        _ row: ProjectCorrespondentRowPresentation
    ) -> some View {
        let option = row.option
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
            Button {
                apply(row.selectionMutation)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(OhiaColors.textSecondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OhiaColors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let detail = option.detail, detail.isEmpty == false {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(OhiaColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(matchCountCopy(option.currentMatchCount))
                            .font(.caption)
                            .foregroundStyle(OhiaColors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            row.isSelected
                                ? OhiaColors.chipActiveForeground
                                : OhiaColors.textTertiary
                        )
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.displayName)
            .accessibilityValue(row.isSelected ? "Selected" : "Not selected")
            .accessibilityHint(row.isSelected
                ? "Removes this correspondent"
                : "Selects this correspondent")
            .accessibilityAddTraits(row.isSelected ? .isSelected : [])

            }
            if row.isSelected {
                HStack(spacing: 14) {
                    ForEach(ProjectCorrespondentRolePresentation.roles, id: \.self) { role in
                        Toggle(
                            role.projectConfigurationTitle,
                            isOn: Binding(
                                get: { row.selectedRoles.contains(role) },
                                set: { applyRole(role, isSelected: $0, to: row) }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .accessibilityHint("Controls whether \(option.displayName) matches mail in the \(role.projectConfigurationTitle) field")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            SettingsRowDivider()
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedPaths: [ProjectCorrespondentSelectionPath] {
        let groups = (state.draft?.groups ?? [])
            .filter { $0.kind == .match }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        return groups.flatMap { group in
            group.conditions
                .filter { $0.facet == .correspondent && $0.polarity == .include }
                .sorted { lhs, rhs in
                    if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .compactMap { condition in
                    let stableKeys = Array(Set(condition.values)).sorted()
                    guard stableKeys.isEmpty == false else { return nil }
                    return ProjectCorrespondentSelectionPath(
                        groupID: group.id,
                        conditionID: condition.id,
                        stableKeys: stableKeys,
                        role: condition.correspondentRole ?? .involves
                    )
                }
        }
    }

    private func apply(_ mutation: ProjectCorrespondentSelectionMutation) {
        switch mutation {
        case let .select(stableKey, roles):
            state.setDefaultCorrespondentRoles(stableKey, roles: roles)
        case let .deselect(stableKeys):
            for stableKey in stableKeys {
                state.setDefaultCorrespondent(stableKey, isSelected: false)
            }
        }
    }

    private func applyRole(
        _ role: MailProjectCorrespondentRole,
        isSelected: Bool,
        to row: ProjectCorrespondentRowPresentation
    ) {
        let mutation = row.roleSelectionMutation(role: role, isSelected: isSelected)
        for stableKey in mutation.stableKeys {
            state.setDefaultCorrespondentRoles(stableKey, roles: mutation.roles)
        }
    }

    private func matchCountCopy(_ count: Int) -> String {
        count == 1 ? "1 current message" : "\(count) current messages"
    }
}

struct ProjectMailingListsEditorView: View {
    @Bindable var state: ProjectConfigurationState

    @State private var query = ""
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        let selectedKeys = selectedListKeys
        let selectedOptions = allOptions.filter { selectedKeys.contains($0.stableKey) }
        LazyVStack(alignment: .leading, spacing: 18) {
            OhiaSettingsCard("Lists") {
                SettingsBlock {
                    TextField("Search mailing lists", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchIsFocused)
                        .accessibilityLabel("Search mailing lists")
                    Text("Select mailing lists whose messages may be included automatically. Lists are identified independently from individual correspondents.")
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
            }

            listCard(
                title: "Selected Lists",
                emptyCopy: "No mailing lists selected.",
                options: selectedOptions,
                selectedKeys: selectedKeys
            )

            if normalizedQuery.isEmpty == false {
                listCard(
                    title: "Search Results",
                    emptyCopy: "No mailing lists match this search.",
                    options: state.searchableValues(for: .mailingLists, query: normalizedQuery),
                    selectedKeys: selectedKeys
                )
            }
        }
        .onAppear { searchIsFocused = true }
    }

    private var allOptions: [ProjectRuleValueOption] {
        state.searchableValues(for: .mailingLists, query: "")
    }

    private var selectedListKeys: Set<String> {
        Set((state.draft?.groups ?? [])
            .filter { $0.kind == .match }
            .flatMap(\.conditions)
            .filter { $0.facet == .mailingList && $0.polarity == .include }
            .flatMap(\.values))
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func listCard(
        title: String,
        emptyCopy: String,
        options: [ProjectRuleValueOption],
        selectedKeys: Set<String>
    ) -> some View {
        OhiaSettingsCard(title) {
            if options.isEmpty {
                SettingsCaption(emptyCopy)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(options) { option in
                        let isSelected = selectedKeys.contains(option.stableKey)
                        Button {
                            state.setDefaultMailingList(
                                option.stableKey,
                                isSelected: isSelected == false
                            )
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "list.bullet.rectangle")
                                    .foregroundStyle(OhiaColors.textSecondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(OhiaColors.textPrimary)
                                    if let detail = option.detail, detail.isEmpty == false {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(OhiaColors.textSecondary)
                                    }
                                    Text(option.currentMatchCount == 1
                                        ? "1 current message"
                                        : "\(option.currentMatchCount) current messages")
                                        .font(.caption)
                                        .foregroundStyle(OhiaColors.textTertiary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected
                                        ? OhiaColors.chipActiveForeground
                                        : OhiaColors.textTertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.displayName)
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .overlay(alignment: .bottom) { SettingsRowDivider() }
                    }
                }
            }
        }
    }
}
