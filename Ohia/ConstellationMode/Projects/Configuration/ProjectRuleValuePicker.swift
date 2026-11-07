import SwiftUI
import OhiaML

struct ProjectRuleValuePicker: View {
    @Bindable var state: ProjectConfigurationState
    let section: ProjectRuleValuePickerSection
    let initialSelection: Set<String>
    let onApply: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selection: Set<String>

    init(
        state: ProjectConfigurationState,
        section: ProjectRuleValuePickerSection,
        initialSelection: Set<String>,
        onApply: @escaping (Set<String>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.section = section
        self.initialSelection = initialSelection
        self.onApply = onApply
        self.onCancel = onCancel
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ComposerSectionHeader(title: section.title, symbolName: "list.bullet.rectangle")
                Spacer()
                Text("Existing values only")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            .padding(14)

            TextField("Search \(section.title)", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            if selection.isEmpty == false {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Selected Values")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(OhiaColors.textSecondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130), spacing: 6)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(selection.sorted(), id: \.self) { stableKey in
                            Button {
                                selection.remove(stableKey)
                            } label: {
                                Label(displayName(for: stableKey), systemImage: "xmark")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.emblem)
                            .help("Remove \(displayName(for: stableKey))")
                            .accessibilityLabel("Remove \(displayName(for: stableKey))")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Divider().overlay(OhiaColors.glassBorder)

            ScrollView {
                LazyVStack(spacing: 7) {
                    let values = state.searchableValues(for: section, query: query)
                    if values.isEmpty {
                        ProjectConfigurationEmptyState(
                            title: "No matching values",
                            detail: "Project rules can use only metadata already present in your mailbox.",
                            symbolName: "magnifyingglass"
                        )
                        .frame(minHeight: 220)
                    } else {
                        ForEach(values) { value in
                            Button {
                                if selection.contains(value.stableKey) {
                                    selection.remove(value.stableKey)
                                } else {
                                    selection.insert(value.stableKey)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selection.contains(value.stableKey)
                                        ? "checkmark.circle.fill"
                                        : "circle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(value.displayName)
                                            .lineLimit(1)
                                        if let detail = value.detail, detail.isEmpty == false {
                                            Text(detail)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(OhiaColors.textSecondary)
                                                .lineLimit(2)
                                        }
                                        Text("\(value.currentMatchCount) current matches")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(OhiaColors.textTertiary)
                                    }
                                    Spacer()
                                    if !value.isValid {
                                        Text("Unavailable")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(OhiaColors.ohiaRed)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.emblem)
                        }
                    }
                }
                .padding(14)
            }

            Divider().overlay(OhiaColors.glassBorder)
            HStack {
                Text("\(selection.count) selected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OhiaColors.textSecondary)
                Spacer()
                Button("Cancel", systemImage: "xmark", action: onCancel)
                    .buttonStyle(.emblem)
                Button("Apply", systemImage: "checkmark") {
                    onApply(selection)
                }
                .buttonStyle(.emblem)
            }
            .padding(14)
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(OhiaColors.composerPanelBackground)
        .environment(\.colorScheme, .dark)
    }

    private func displayName(for stableKey: String) -> String {
        state.searchableValues(for: section, query: "")
            .first { $0.stableKey == stableKey }?.displayName ?? stableKey
    }
}
