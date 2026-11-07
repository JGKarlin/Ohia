import SwiftUI

/// The shared visual language for a pane whose content set is empty.
/// Callers provide context; this view owns the appearance and centering.
struct OhiaEmptyPaneStateView: View {
    let systemName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OhiaColors.textSecondary)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(OhiaColors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
