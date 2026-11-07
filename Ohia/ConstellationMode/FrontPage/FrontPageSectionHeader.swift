import SwiftUI
import OhiaCore
import OhiaML

/// Section rule for a Purpose band: the Purpose label as a masthead-style
/// rule, the article count, and the expand/collapse affordance shown when the
/// section has overflow. Both directions use complete labels without
/// truncation markers.
struct FrontPageSectionHeader: View {
    let section: FrontPageSection
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.displayLabel.uppercased())
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(OhiaColors.textPrimary)

            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)

            Text("\(section.availableInMomentsWindow)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textTertiary)

            if section.hasMore {
                Button(action: onToggleExpanded) {
                    Text(expandLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded
                    ? "Collapse \(section.displayLabel)"
                    : "Show more \(section.displayLabel)")
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var expandLabel: String {
        if isExpanded {
            return "Show less"
        }
        let hidden = section.availableInMomentsWindow - section.shownCount
        return Self.moreLabel(displayLabel: section.displayLabel, hiddenCount: hidden)
    }

    static func moreLabel(displayLabel: String, hiddenCount: Int) -> String {
        "More \(displayLabel) (\(hiddenCount))"
    }
}
