import SwiftUI
import SwiftData
import OhiaCore

struct ProjectConfigurationSourcePane: View {
    @Bindable var state: ProjectConfigurationState
    @AppStorage(ContentLanguagesStore.defaultsKey, store: OhiaSharedDefaults.store)
    private var contentLanguagesData = Data()
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @FocusState private var focusedSectionID: String?
    @State private var hoveredSection: ProjectConfigurationSection?

    var body: some View {
        let groups = visibleGroups
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    Text(group.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, group == groups.first ? 4 : 14)
                        .padding(.bottom, 3)

                    ForEach(group.sections) { section in
                        navigationRow(section)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OhiaColors.composerPanelBackground)
        .onMoveCommand(perform: moveSelection)
        .onChange(of: visibleSections, initial: true) { _, sections in
            guard sections.contains(state.selectedSection) == false,
                  let fallback = sections.first else { return }
            state.selectedSection = fallback
        }
    }

    private func navigationRow(_ section: ProjectConfigurationSection) -> some View {
        let isSelected = state.selectedSection == section
        let isHovering = hoveredSection == section
        return Button {
            select(section)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground(isSelected: isSelected, isHovering: isHovering))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(background(isSelected: isSelected, isHovering: isHovering))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focused($focusedSectionID, equals: section.id)
        .onHover { isHovering in
            hoveredSection = isHovering ? section : nil
        }
        .accessibilityLabel(section.title)
        .accessibilityHint("Shows \(section.title) project settings")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func foreground(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected { return OhiaColors.chipActiveForeground }
        if isHovering { return OhiaColors.textPrimary }
        return OhiaColors.textSecondary
    }

    private func background(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected { return OhiaColors.chipActiveBackground }
        if isHovering { return OhiaColors.surface(0.06) }
        return .clear
    }

    private func select(_ section: ProjectConfigurationSection) {
        state.selectedSection = section
        focusedSectionID = section.id
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = visibleSections
        let focusedSection = focusedSectionID.flatMap { id in
            sections.first { $0.id == id }
        }
        guard let currentIndex = sections.firstIndex(of: focusedSection ?? state.selectedSection) else {
            select(sections[0])
            return
        }

        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(sections.startIndex, currentIndex - 1)
        case .down:
            nextIndex = min(sections.index(before: sections.endIndex), currentIndex + 1)
        default:
            return
        }
        select(sections[nextIndex])
    }

    private var configuredContentLanguageIDs: [String] {
        ProjectLanguageConfigurationPresentation.configuredLanguageIDs(
            accounts: accounts.map {
                ProjectAccountLanguageConfiguration(
                    accountID: $0.id,
                    languageIDs: $0.draftLanguages
                )
            },
            selectedAccountIDs: state.draft?.accountIDs ?? [],
            fallbackLanguageIDs: ContentLanguagesStore.modelSupportedIDs(
                from: contentLanguagesData
            )
        )
    }

    private var visibleGroups: [ProjectConfigurationNavigationGroup] {
        ProjectConfigurationNavigation.visibleGroups(
            configuredContentLanguageIDs: configuredContentLanguageIDs
        )
    }

    private var visibleSections: [ProjectConfigurationSection] {
        visibleGroups.flatMap(\.sections)
    }
}
