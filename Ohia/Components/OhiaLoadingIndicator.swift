import SwiftUI

/// Shared no-text loading affordance for transient app surfaces.
struct OhiaLoadingIndicator: View {
    let accessibilityLabel: String

    init(accessibilityLabel: String = "Loading") {
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(OhiaColors.chipActiveBorder)
            .scaleEffect(0.82)
            .frame(width: 36, height: 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(accessibilityLabel)
    }
}
