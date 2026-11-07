import SwiftUI

enum ConstellationLensSurfaceStatus: Equatable {
    case loading(accessibilityLabel: String)
    case noAccountsSelected
    case noMessagesMeetFilter
}

struct ConstellationLensSurfaceStatusView: View {
    let status: ConstellationLensSurfaceStatus
    /// When false the opaque space backing is omitted so a backdrop behind
    /// this view (the People / Meanings `NightSkyView`) stays visible through
    /// the loading / empty status — the starfield must not drop to flat black
    /// during lens switches or filter-driven reloads.
    var paintsBackground: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if paintsBackground {
                OhiaColors.spaceBackground
            }

            switch status {
            case .loading(let accessibilityLabel):
                OhiaLoadingIndicator(accessibilityLabel: accessibilityLabel)
            case .noAccountsSelected:
                OhiaEmptyPaneStateView(
                    systemName: "tray.circle",
                    title: "No accounts are currently selected",
                    detail: "Select at least one account in Destination to bring messages into view."
                )
            case .noMessagesMeetFilter:
                OhiaEmptyPaneStateView(
                    systemName: "line.3.horizontal.decrease.circle",
                    title: "No messages meet the filter criteria",
                    detail: "Adjust the current filters to bring messages into view."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The `NightSkyView` backdrop (when `paintsBackground == false`) is
        // always dark regardless of system appearance (§18 exception), so pin
        // the status content to the dark register there — otherwise the
        // empty-state label + symbol resolve to dark grey in Light mode and
        // read dark-on-near-black. Other surfaces keep the system appearance.
        .environment(\.colorScheme, paintsBackground ? colorScheme : .dark)
        .accessibilityElement(children: .combine)
    }

}
