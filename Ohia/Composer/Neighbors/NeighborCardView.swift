import SwiftUI
import OhiaML

struct NeighborCardView: View {
    let neighbor: NeighborData
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(neighbor.senderName)
                        .font(OhiaTypography.neighborTitle)
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", neighbor.similarityScore * 100))
                        .font(OhiaTypography.neighborScore)
                        .foregroundStyle(OhiaColors.textTertiary)
                }
                Text(neighbor.subject)
                    .font(OhiaTypography.cardDetail)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(1)
                Text(neighbor.relationshipLabel)
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                Text(neighbor.excerpt)
                    .font(OhiaTypography.neighborExcerpt)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineLimit(2)
            }
            .padding(8)
            .background(OhiaColors.surface(isSelected ? 0.05 : 0.02))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
