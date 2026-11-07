import SwiftUI

/// Slim trailing band. Holds no chrome — the header carries the visible release
/// (`xmark`) button and Esc is wired at the scene level — so the band exists
/// only to seat the bottom edge a hair below the body divider. Kept as a
/// dedicated view so `LockedEmailCardFooterHeightPreferenceKey` continues to
/// report a non-nil chrome height to the layout coordinator.
struct LockedEmailCardFooter: View {
    let onRelease: () -> Void

    var body: some View {
        Color.clear
            .frame(height: 2)
    }
}
