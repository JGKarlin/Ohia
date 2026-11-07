import SwiftUI

public enum SidebarTab: String, CaseIterable, Identifiable {
    case search, ask
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .search: return "Search"
        case .ask:    return "Ask"
        }
    }
    public var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .ask:    return "bubble.left"
        }
    }
}

public struct SidebarTabPicker: View {
    @Binding public var tabRaw: String   // "search" | "ask"

    public init(tabRaw: Binding<String>) {
        self._tabRaw = tabRaw
    }

    private var selected: SidebarTab {
        SidebarTab(rawValue: tabRaw) ?? .search
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(SidebarTab.allCases) { tab in
                pill(for: tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(OhiaColors.surface(0.05))
        )
    }

    @ViewBuilder
    private func pill(for tab: SidebarTab) -> some View {
        let isSelected = (selected == tab)
        Button(action: { tabRaw = tab.rawValue }) {
            HStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? OhiaColors.chipActiveBackground : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? OhiaColors.chipActiveBorder : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
