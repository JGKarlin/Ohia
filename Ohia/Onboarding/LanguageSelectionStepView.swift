import SwiftUI
import OhiaCore

struct OrderedLanguageSelectionState: Equatable, Sendable {
    private(set) var selectedIDs: [String]

    init(persistedIDs: [String] = []) {
        selectedIDs = Self.canonicalized(persistedIDs)
    }

    var primaryID: String? { selectedIDs.first }
    var canContinue: Bool { selectedIDs.isEmpty == false }

    mutating func toggle(_ identifier: String) {
        guard let id = LocalModelLanguageSupport.canonicalLanguageID(for: identifier) else {
            return
        }
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(id)
        }
    }

    static func canonicalized(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers
            .compactMap(LocalModelLanguageSupport.canonicalLanguageID(for:))
            .filter { seen.insert($0).inserted }
    }
}

struct LanguageSelectionStepView: View {
    let languages: [ContentLanguageOption]
    @Binding var selectedLanguages: [String]
    let onContinue: () -> Void

    init(
        languages: [ContentLanguageOption] = ContentLanguageOption.supported,
        selectedLanguages: Binding<[String]>,
        onContinue: @escaping () -> Void
    ) {
        self.languages = languages
        self._selectedLanguages = selectedLanguages
        self.onContinue = onContinue
    }

    private var selectionState: OrderedLanguageSelectionState {
        OrderedLanguageSelectionState(persistedIDs: selectedLanguages)
    }

    var body: some View {
        ZStack {
            NightSkyView(showsMilkyWay: false)
            NightSkyNebulaOverlay()

            VStack(spacing: 0) {
                Spacer()

                Text("Choose languages")
                    .font(OhiaTypography.stepHeading)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.bottom, 24)

                LanguageSelectionFlowLayout(spacing: 10) {
                    ForEach(languages) { language in
                        LanguageSelectionChip(
                            language: language,
                            isSelected: selectionState.selectedIDs.contains(language.id),
                            isPrimary: selectionState.primaryID == language.id
                        ) {
                            toggle(language.id)
                        }
                    }
                }
                .frame(maxWidth: 520)
                .padding(.bottom, 20)

                Text("Choose the languages you use. Your first choice is your primary language. You can change this later in Settings.")
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                Spacer()

                Button(action: onContinue) {
                    Text("Continue")
                        .font(OhiaTypography.button)
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 40, verticalPadding: 12))
                .disabled(selectionState.canContinue == false)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 48)
        }
        .task {
            canonicalizePersistedSelection()
        }
    }

    private func toggle(_ identifier: String) {
        var state = selectionState
        state.toggle(identifier)
        selectedLanguages = state.selectedIDs
    }

    private func canonicalizePersistedSelection() {
        let canonical = OrderedLanguageSelectionState.canonicalized(selectedLanguages)
        if canonical != selectedLanguages {
            selectedLanguages = canonical
        }
    }
}

private struct LanguageSelectionChip: View {
    let language: ContentLanguageOption
    let isSelected: Bool
    let isPrimary: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }

                Text(language.displayName)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))

                if isPrimary {
                    Text("Primary")
                        .font(OhiaTypography.caption)
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(OhiaColors.chipActiveForeground.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .fixedSize()
            .foregroundStyle(isSelected ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        isSelected ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.displayName)
        .accessibilityValue(isPrimary ? "Selected, primary language" : (isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LanguageSelectionFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > containerWidth, currentX > 0 {
                currentY += rowHeight + spacing
                currentX = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }

        return CGSize(width: containerWidth, height: currentY + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentY += rowHeight + spacing
                currentX = bounds.minX
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
    }
}
