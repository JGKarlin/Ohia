import SwiftUI
import OhiaML

struct NeighborPanelView: View {
    let title: String
    let symbolName: String
    let neighbors: [NeighborData]
    let selectedNeighborID: UUID?
    let onSelect: (NeighborData) -> Void
    /// Optional readout rendered between the section header and the list — the
    /// Style panel passes its `PersonalizationStrip` here.
    var header: AnyView? = nil

    var body: some View {
        GlassPane(accentColor: OhiaColors.chipActiveForeground, isForeground: false) {
            VStack(alignment: .leading, spacing: 6) {
                ComposerSectionHeader(title: title, symbolName: symbolName, count: neighbors.count)
                if let header {
                    header
                }
                if neighbors.isEmpty {
                    Spacer()
                    Text("No \(title.lowercased())")
                        .font(OhiaTypography.cardDetail)
                        .foregroundStyle(OhiaColors.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(neighbors) { neighbor in
                                NeighborCardView(
                                    neighbor: neighbor,
                                    isSelected: selectedNeighborID == neighbor.id,
                                    onTap: { onSelect(neighbor) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
