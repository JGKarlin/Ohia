import SwiftUI

/// The Settings night-sky framing reused by every Composer presentation.
/// Light Mode deliberately stays on the existing system-aligned surface.
struct ComposerNightSkyBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            ZStack {
                NightSkyView(showsMilkyWay: false, twinkles: false)
                NightSkyNebulaOverlay()
            }
        } else {
            OhiaColors.toolbarBackground
        }
    }
}

/// A black Composer card framed by the shared nebula in Dark Mode. Sheets
/// and popovers use this after setting their content size, which leaves a
/// narrow atmospheric gutter without changing their Light Mode geometry.
private struct ComposerPresentationFrameModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let inset: CGFloat
    let cornerRadius: CGFloat
    let usesToolbarBackgroundInLightMode: Bool

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            let shape = RoundedRectangle(cornerRadius: cornerRadius)
            content
                .background(OhiaColors.composerPanelBackground)
                .overlay { shape.strokeBorder(OhiaColors.glassBorder, lineWidth: 1) }
                .clipShape(shape)
                .padding(inset)
                .background(ComposerNightSkyBackdrop())
        } else if usesToolbarBackgroundInLightMode {
            content.background(OhiaColors.toolbarBackground)
        } else {
            content
        }
    }
}

extension View {
    func composerPresentationFrame(
        inset: CGFloat = 10,
        cornerRadius: CGFloat = 10,
        usesToolbarBackgroundInLightMode: Bool = false
    ) -> some View {
        modifier(
            ComposerPresentationFrameModifier(
                inset: inset,
                cornerRadius: cornerRadius,
                usesToolbarBackgroundInLightMode: usesToolbarBackgroundInLightMode
            )
        )
    }
}
