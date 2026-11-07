// Ohia/Settings/SettingsView.swift
// Top-level Settings window — bound to ⌘, via the macOS Settings scene.
//
// Navigation is a System-Settings-style left sidebar rather than the native
// macOS Settings `TabView` strip: that strip's selection highlight is AppKit
// chrome that ignores both SwiftUI `.tint` and the app's AccentColor asset,
// so it can only render in the system accent (blue) — and a horizontal strip
// stopped fitting once the pane count reached ten. The sidebar renders the
// selected pane as a faint active-filter accent pill (`chipActive*`) — green
// in Light, stamen-yellow in Dark — matching §18 / §2.5 of the design docs.

import SwiftUI
import SwiftData
import OhiaCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, model, languages, accounts, signatures, memories, sources, subscriptions, training, developer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:       "General"
        case .accounts:      "Accounts"
        case .signatures:    "Signatures"
        case .memories:      "Memories"
        case .sources:       "Sources"
        case .subscriptions: "Lists"
        case .languages:     "Languages"
        case .model:         "Models"
        case .training:      "Training"
        case .developer:     "Developer"
        }
    }

    var systemImage: String {
        switch self {
        case .general:       "gearshape"
        case .accounts:      "envelope"
        case .signatures:    "signature"
        case .memories:      "brain"
        case .sources:       "doc.text.magnifyingglass"
        case .subscriptions: "person.3"
        case .languages:     "globe"
        case .model:         "cpu"
        case .training:      "waveform.path.ecg"
        case .developer:     "hammer"
        }
    }
}

/// One sidebar group: an optional uppercase header over its panes.
struct SettingsSidebarSection: Identifiable {
    let header: String?
    let tabs: [SettingsTab]
    var id: String { header ?? tabs.first?.rawValue ?? "" }

    /// Top-to-bottom order of the sidebar (independent of `allCases`).
    static let mainSections: [SettingsSidebarSection] = [
        SettingsSidebarSection(header: nil, tabs: [.general]),
        SettingsSidebarSection(header: "Mail", tabs: [.accounts, .languages, .signatures, .subscriptions]),
        SettingsSidebarSection(
            header: "Intelligence",
            tabs: [.model, .sources, .memories, .training]
        ),
    ]

    /// Standalone footer tab — pinned to the sidebar bottom like General at the top.
    static let footerTabs: [SettingsTab] = [.developer]

    static var displayOrder: [SettingsSidebarSection] {
        mainSections + [SettingsSidebarSection(header: nil, tabs: footerTabs)]
    }
}

struct SettingsView: View {
    @AppStorage("selectedSettingsTab") private var selectedRaw = SettingsTab.general.rawValue
    @State private var tabsVisible = false
    @Environment(\.colorScheme) private var colorScheme

    private static let contentRevealDelay = Duration.milliseconds(160)
    private static let sidebarWidth: CGFloat = 190

    private var selectedTab: SettingsTab {
        SettingsTab(rawValue: selectedRaw) ?? .general
    }

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color.black
            }

            if tabsVisible {
                settingsContent
                    .transition(.opacity)
            } else {
                OhiaLoadingIndicator(accessibilityLabel: "Loading settings")
                    .transition(.opacity)
            }
        }
        .frame(width: 960, height: 620)
        .modifier(SettingsWindowBackgroundStyle(isDark: colorScheme == .dark))
        .task {
            await revealSettingsTabs()
        }
        .animation(.easeInOut(duration: 0.18), value: tabsVisible)
    }

    private var settingsContent: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(sidebarBackground)
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 1)
            selectedTabView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // The old top-strip layout applied `.padding()` around the
                // whole window content; the panes' own margins were sized
                // against it. Keep an equivalent inset on the content side
                // only — the sidebar stays full-bleed.
                .padding(16)
                // Distinct identity per tab so each renders fresh (top of
                // scroll, own @State) instead of inheriting the previous
                // tab's ScrollView offset via shared structural identity.
                .id(selectedTab)
                .background(contentBackdrop)
        }
        // Mode-aware active accent (deepened leaf-green in Light, stamen-
        // yellow in Dark) replaces the system blue across every native
        // control inside the panes — segmented pickers, toggles, sliders,
        // progress views, menu pickers, and plain link buttons.
        .tint(OhiaColors.chipActiveForeground)
        // Restyles every GroupBox in the GroupBox-based panes (Accounts,
        // Models, Developer) as a black card in one place — their system fill
        // would otherwise render the night sky through it. Dark only.
        .settingsGroupBoxStyling()
    }

    /// The left column. In dark it is a black slab — the same black as the
    /// cards in the right column, since both were the one lighter shade
    /// (`#313130`) the window used for "areas with settings". Light keeps the
    /// faint shade it always had over the system window background.
    private var sidebarBackground: Color {
        colorScheme == .dark ? .black : OhiaColors.surface(0.03)
    }

    /// What frames the right column: the band-less night sky under the
    /// two-colour (blue/teal) nebula wash — the same pairing the Constellation
    /// lenses fly through — replacing the darker `#2B2A29` shade. Dark only;
    /// light keeps the standard macOS window background (§18: two paired
    /// palettes, neither is "more true").
    @ViewBuilder
    private var contentBackdrop: some View {
        if colorScheme == .dark {
            ZStack {
                NightSkyView(showsMilkyWay: false, twinkles: false)
                NightSkyNebulaOverlay()
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSidebarSection.mainSections) { section in
                        sidebarSection(section)
                    }
                }
                .padding(10)
            }
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSidebarSection.footerTabs) { tab in
                    SettingsSidebarRow(
                        tab: tab,
                        isSelected: tab == selectedTab
                    ) {
                        selectedRaw = tab.rawValue
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func sidebarSection(_ section: SettingsSidebarSection) -> some View {
        if let header = section.header {
            Text(header.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 3)
        }
        ForEach(section.tabs) { tab in
            SettingsSidebarRow(
                tab: tab,
                isSelected: tab == selectedTab
            ) {
                selectedRaw = tab.rawValue
            }
        }
    }

    @ViewBuilder
    private var selectedTabView: some View {
        switch selectedTab {
        case .general:       GeneralSettingsView()
        case .accounts:      AccountsListView()
        case .signatures:    SignaturesSettingsView()
        case .memories:      MemoriesSettingsView()
        case .sources:       SourcesSettingsView()
        case .subscriptions: SubscriptionsSettingsView()
        case .languages:     LanguagesSettingsView()
        case .model:         ModelSettingsView()
        case .training:      TrainingSettingsView()
        case .developer:     DeveloperSettingsView()
        }
    }

    @MainActor
    private func revealSettingsTabs() async {
        guard !tabsVisible else { return }
        try? await Task.sleep(for: Self.contentRevealDelay)
        guard !Task.isCancelled else { return }
        tabsVisible = true
    }
}

/// Gives Dark Mode Settings a black window canvas from the first frame and
/// removes the standard window-toolbar material so the title bar shares it.
/// Light Mode remains under macOS's default Settings window styling.
private struct SettingsWindowBackgroundStyle: ViewModifier {
    let isDark: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isDark {
            content
                .containerBackground(Color.black, for: .window)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// One icon-beside-label sidebar row (15pt medium icon in a fixed 20pt
/// column, 13pt label). The selected row renders as a faint active-filter
/// accent pill (`chipActive*`); unselected rows are muted and lift to a
/// faint surface tint on hover.
private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? OhiaColors.chipActiveBorder : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var foreground: Color {
        if isSelected { return OhiaColors.chipActiveForeground }
        if isHovering { return OhiaColors.textPrimary }
        return OhiaColors.textSecondary
    }

    private var backgroundFill: Color {
        if isSelected { return OhiaColors.chipActiveBackground }
        if isHovering { return OhiaColors.surface(0.06) }
        return Color.clear
    }
}
