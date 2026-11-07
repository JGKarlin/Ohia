import SwiftUI
import OhiaCore
import OhiaML

/// Permanent sidebar overlay anchored to the leading or trailing edge of
/// `ConstellationModeView`. Two tabs (Search, Ask). Side and active tab
/// persist via `@AppStorage`. Hidden during onboarding mode (parity with
/// top/bottom bars).
public struct ConstellationSidebar: View {

    // Tab persistence (raw strings to fit @AppStorage value type).
    @Binding public var tabRaw: String
    public let clearsWindowControls: Bool

    // Search tab inputs.
    @Binding public var searchQuery: String
    public let searchModel: ConstellationSearchModel   // computed upstream
    public let searchMatchIndex: Int
    public let onSearchSubmit: () -> Void
    public let onSelectSearchLane: (LexicalSearchLane) -> Void
    public let onSelectMatch: (Int) -> Void            // absolute match index
    public let onWarpMatch: (Int) -> Void              // absolute match index

    // Ask tab inputs (passed through to ConstellationAskTab).
    @Bindable public var qaVM: QAViewModel
    public let activeFilter: @MainActor @Sendable () async -> FilterSpec
    public let threadContextProvider: @MainActor @Sendable ([RetrievalResult]) async -> AskThreadExpansion
    public let sourceLookup: (Int64) -> VectorRecord?
    public let onCitationHover: (Int64?) -> Void
    public let onCitationClick: (Int64) -> Void
    public let onClose: () -> Void

    public init(
        tabRaw: Binding<String>,
        clearsWindowControls: Bool = true,
        searchQuery: Binding<String>,
        searchModel: ConstellationSearchModel,
        searchMatchIndex: Int,
        onSearchSubmit: @escaping () -> Void,
        onSelectSearchLane: @escaping (LexicalSearchLane) -> Void,
        onSelectMatch: @escaping (Int) -> Void,
        onWarpMatch: @escaping (Int) -> Void,
        qaVM: QAViewModel,
        activeFilter: @escaping @MainActor @Sendable () async -> FilterSpec,
        threadContextProvider: @escaping @MainActor @Sendable ([RetrievalResult]) async -> AskThreadExpansion = { _ in .empty },
        sourceLookup: @escaping (Int64) -> VectorRecord?,
        onCitationHover: @escaping (Int64?) -> Void,
        onCitationClick: @escaping (Int64) -> Void,
        onClose: @escaping () -> Void
    ) {
        self._tabRaw = tabRaw
        self.clearsWindowControls = clearsWindowControls
        self._searchQuery = searchQuery
        self.searchModel = searchModel
        self.searchMatchIndex = searchMatchIndex
        self.onSearchSubmit = onSearchSubmit
        self.onSelectSearchLane = onSelectSearchLane
        self.onSelectMatch = onSelectMatch
        self.onWarpMatch = onWarpMatch
        self.qaVM = qaVM
        self.activeFilter = activeFilter
        self.threadContextProvider = threadContextProvider
        self.sourceLookup = sourceLookup
        self.onCitationHover = onCitationHover
        self.onCitationClick = onCitationClick
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(OhiaColors.glassBorder)
            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OhiaColors.spaceBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SidebarTabPicker(tabRaw: $tabRaw)
            Spacer()
            SidebarPanelChromeButtons(
                closeLabel: "Close Search/Ask",
                onClose: onClose
            )
        }
        .padding(.horizontal, 10)
        // Top inset clears the macOS traffic-light controls so the close
        // control stays fully clickable when the sidebar owns the window top.
        // When the toolbar spans above the split, the sidebar has already been
        // pushed below those controls and can use the compact inset.
        .padding(.top, clearsWindowControls ? 28 : 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var tabBody: some View {
        switch SidebarTab(rawValue: tabRaw) ?? .search {
        case .search:
            ConstellationSearchTab(
                searchQuery: $searchQuery,
                model: searchModel,
                matchIndex: searchMatchIndex,
                onSubmit: onSearchSubmit,
                onSelectLane: onSelectSearchLane,
                onSelectMatch: onSelectMatch,
                onWarpMatch: onWarpMatch
            )
        case .ask:
            ConstellationAskTab(
                viewModel: qaVM,
                activeFilter: activeFilter,
                threadContextProvider: threadContextProvider,
                sourceLookup: sourceLookup,
                onCitationHover: onCitationHover,
                onCitationClick: onCitationClick
            )
        }
    }
}
