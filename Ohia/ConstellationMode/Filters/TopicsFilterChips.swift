import SwiftUI
import OhiaCore

private enum BuiltInCategoryFilterEntry: Hashable {
    case purpose(MailPurpose)
    case mailingLists

    static let alphabeticalOtherLast: [BuiltInCategoryFilterEntry] = {
        let entries = MailPurpose.allCases
            .filter { $0 != .other }
            .map(BuiltInCategoryFilterEntry.purpose) + [.mailingLists]
        return entries.sorted {
            $0.displayLabel.localizedStandardCompare($1.displayLabel) == .orderedAscending
        } + [.purpose(.other)]
    }()

    var displayLabel: String {
        switch self {
        case .purpose(let purpose): purpose.displayLabel
        case .mailingLists: "Lists"
        }
    }
}

/// Compact state map for the flat shared-category filter.
public struct TopicsFilterChips: View {
    @Binding public var purposes: Set<MailPurpose>?
    @Binding public var mailingListCategoryIncluded: Bool?
    @Binding public var customCategoryKeys: Set<String>?
    public let customCatalog: [CustomMailCategoryDescriptor]

    public init(
        purposes: Binding<Set<MailPurpose>?>,
        mailingListCategoryIncluded: Binding<Bool?>,
        customCategoryKeys: Binding<Set<String>?>,
        customCatalog: [CustomMailCategoryDescriptor]
    ) {
        _purposes = purposes
        _mailingListCategoryIncluded = mailingListCategoryIncluded
        _customCategoryKeys = customCategoryKeys
        self.customCatalog = customCatalog
    }

    public var body: some View {
        let entries = entries
        let width = FilterRatioBarMetrics.width(entryCount: entries.count)

        FilterRatioBar(entries: entries)
            .chipMetrics(
                wordWidth: width,
                iconWidth: width,
                isPressed: entries.contains { !$0.isActive }
            )
    }

    /// Labeled slots in alphabetical order with Other last — built-ins then
    /// user categories — matching the popover's row order so a hash's tooltip
    /// names the same category its menu row toggles.
    private var entries: [FilterRatioBar.Entry] {
        let purposeSelection = purposes ?? Set(MailPurpose.allCases)
        let catalogKeys = Set(customCatalog.map(\.key))
        let customSelection = (customCategoryKeys ?? catalogKeys).intersection(catalogKeys)
        let builtInEntries = BuiltInCategoryFilterEntry.alphabeticalOtherLast.map { entry -> FilterRatioBar.Entry in
            switch entry {
            case .purpose(let purpose):
                FilterRatioBar.Entry(
                    label: purpose.displayLabel,
                    isActive: purposeSelection.contains(purpose),
                    onToggle: { togglePurpose(purpose) }
                )
            case .mailingLists:
                FilterRatioBar.Entry(
                    label: "Lists",
                    isActive: mailingListCategoryIncluded ?? true,
                    onToggle: toggleMailingLists
                )
            }
        }
        let customEntries = alphabeticalCustomCatalog.map { descriptor in
            FilterRatioBar.Entry(
                label: descriptor.displayName,
                isActive: customSelection.contains(descriptor.key),
                onToggle: { toggleCustom(descriptor.key) }
            )
        }
        return builtInEntries + customEntries
    }

    private var alphabeticalCustomCatalog: [CustomMailCategoryDescriptor] {
        customCatalog.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // Toggle semantics identical to the popover rows: remove from the active
    // set, or insert back; collapsing to `nil` when the selection returns to
    // the full default (so a fully-on filter stays the nil "no filter" state).
    private func togglePurpose(_ purpose: MailPurpose) {
        var active = purposes ?? Set(MailPurpose.allCases)
        if active.contains(purpose) { active.remove(purpose) } else { active.insert(purpose) }
        purposes = active == Set(MailPurpose.allCases) ? nil : active
    }

    private func toggleMailingLists() {
        mailingListCategoryIncluded = (mailingListCategoryIncluded ?? true) ? false : nil
    }

    private func toggleCustom(_ key: String) {
        let allKeys = Set(customCatalog.map(\.key))
        var active = (customCategoryKeys ?? allKeys).intersection(allKeys)
        if active.contains(key) { active.remove(key) } else { active.insert(key) }
        customCategoryKeys = active == allKeys ? nil : active
    }
}

/// Shared popover body for one flat category vocabulary: shared purposes,
/// deterministic Lists, and user-created categories.
public struct TopicsFilterMenuRows: View {
    @Binding public var purposes: Set<MailPurpose>?
    @Binding public var mailingListCategoryIncluded: Bool?
    @Binding public var customCategoryKeys: Set<String>?
    public let purposeCounts: [MailPurpose: Int]
    public let mailingListCount: Int?
    public let customCategoryCounts: [String: Int]
    public let customCatalog: [CustomMailCategoryDescriptor]
    public let onCreateCustomCategory: (String) -> Void
    public let onRemoveCustomCategory: (String) -> Void

    @State private var newCategoryName = ""

    public init(
        purposes: Binding<Set<MailPurpose>?>,
        mailingListCategoryIncluded: Binding<Bool?>,
        customCategoryKeys: Binding<Set<String>?>,
        purposeCounts: [MailPurpose: Int] = [:],
        mailingListCount: Int? = nil,
        customCategoryCounts: [String: Int] = [:],
        customCatalog: [CustomMailCategoryDescriptor] = [],
        onCreateCustomCategory: @escaping (String) -> Void = { _ in },
        onRemoveCustomCategory: @escaping (String) -> Void = { _ in }
    ) {
        _purposes = purposes
        _mailingListCategoryIncluded = mailingListCategoryIncluded
        _customCategoryKeys = customCategoryKeys
        self.purposeCounts = purposeCounts
        self.mailingListCount = mailingListCount
        self.customCategoryCounts = customCategoryCounts
        self.customCatalog = customCatalog
        self.onCreateCustomCategory = onCreateCustomCategory
        self.onRemoveCustomCategory = onRemoveCustomCategory
    }

    public var body: some View {
        ForEach(BuiltInCategoryFilterEntry.alphabeticalOtherLast, id: \.self) { entry in
            builtInMenuRow(for: entry)
        }
        if !customCatalog.isEmpty {
            menuDivider
            ForEach(alphabeticalCustomCatalog) { descriptor in
                CustomCategoryMenuRow(
                    name: customRowLabel(for: descriptor),
                    isChecked: activeCustomKeys.contains(descriptor.key),
                    onToggle: { toggleCustom(descriptor.key) },
                    onRemove: { onRemoveCustomCategory(descriptor.key) }
                )
            }
        }
        FilterPopoverClearAllRow(
            isEnabled: hasAnySelection,
            action: clearAll
        )
        FilterPopoverDisplayAllRow(
            isEnabled: isNarrowed,
            action: displayAll
        )
        menuDivider
        newCategoryRow
    }

    @ViewBuilder
    private func builtInMenuRow(for entry: BuiltInCategoryFilterEntry) -> some View {
        switch entry {
        case .purpose(let purpose):
            MenuRow(
                name: counted(
                    purpose.displayLabel,
                    count: purposeCounts[purpose],
                    hasCounts: !purposeCounts.isEmpty
                ),
                symbolName: purpose.systemImageName,
                isChecked: activePurposes.contains(purpose),
                action: { togglePurpose(purpose) }
            )
        case .mailingLists:
            MenuRow(
                name: counted("Lists", count: mailingListCount, hasCounts: mailingListCount != nil),
                symbolName: "person.3",
                isChecked: mailingListCategoryIncluded ?? true,
                action: toggleMailingLists
            )
        }
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(height: 1)
            .padding(.vertical, 3)
    }

    private var newCategoryRow: some View {
        HStack(spacing: 7) {
            TextField("New category name", text: $newCategoryName)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(OhiaColors.textPrimary)
                .onSubmit(commitNewCategory)
            Button(action: commitNewCategory) {
                Text("Add")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(.emblem)
            .disabled(trimmedNewCategoryName.isEmpty)
            .help("Create a custom category; tag \(CustomMailCategory.activationExampleThreshold) example emails to activate it")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var trimmedNewCategoryName: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNewCategory() {
        let name = trimmedNewCategoryName
        guard !name.isEmpty else { return }
        onCreateCustomCategory(name)
        newCategoryName = ""
    }

    private var activePurposes: Set<MailPurpose> {
        purposes ?? Set(MailPurpose.allCases)
    }

    private var allCustomKeys: Set<String> { Set(customCatalog.map(\.key)) }

    private var alphabeticalCustomCatalog: [CustomMailCategoryDescriptor] {
        customCatalog.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var activeCustomKeys: Set<String> {
        (customCategoryKeys ?? allCustomKeys).intersection(allCustomKeys)
    }

    private var hasAnySelection: Bool {
        !activePurposes.isEmpty
            || (mailingListCategoryIncluded ?? true)
            || !activeCustomKeys.isEmpty
    }

    private var isNarrowed: Bool {
        purposes != nil
            || mailingListCategoryIncluded != nil
            || customCategoryKeys != nil
    }

    private func counted(_ label: String, count: Int?, hasCounts: Bool) -> String {
        guard hasCounts else { return label }
        return "\(label) (\((count ?? 0).formatted(.number)))"
    }

    private func customRowLabel(for descriptor: CustomMailCategoryDescriptor) -> String {
        let label = CustomCategoryStore.menuLabel(for: descriptor)
        guard descriptor.status == .active, !customCategoryCounts.isEmpty else { return label }
        return counted(label, count: customCategoryCounts[descriptor.key], hasCounts: true)
    }

    private func togglePurpose(_ purpose: MailPurpose) {
        var active = activePurposes
        if active.contains(purpose) { active.remove(purpose) } else { active.insert(purpose) }
        purposes = active == Set(MailPurpose.allCases) ? nil : active
    }

    private func toggleMailingLists() {
        mailingListCategoryIncluded = (mailingListCategoryIncluded ?? true) ? false : nil
    }

    private func toggleCustom(_ key: String) {
        var active = activeCustomKeys
        if active.contains(key) { active.remove(key) } else { active.insert(key) }
        customCategoryKeys = active == allCustomKeys ? nil : active
    }

    private func clearAll() {
        purposes = []
        mailingListCategoryIncluded = false
        customCategoryKeys = []
    }

    private func displayAll() {
        purposes = nil
        mailingListCategoryIncluded = nil
        customCategoryKeys = nil
    }
}

private struct CustomCategoryMenuRow: View {
    let name: String
    let isChecked: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onToggle) {
                HStack(spacing: 9) {
                    MenuRowCheckbox(isChecked: isChecked)
                    Image(systemName: ToggleIconography.customCategorySymbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                        .frame(width: 16, height: 16)
                    Text(name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.emblem)
            .opacity(hovering ? 1 : 0)
            .help("Remove this category")
            .accessibilityLabel("Remove category \(name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .onHover { hovering = $0 }
    }
}
