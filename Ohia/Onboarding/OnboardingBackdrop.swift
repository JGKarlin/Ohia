import SwiftUI

/// The shared onboarding backdrop: `spaceBackground` with the blue-and-teal
/// `NightSkyNebulaOverlay` wash and a soft accent glow centered in the window
/// so the wizard reads as floating in the constellation void rather than as a
/// separate gray dialog. No Milky Way band — that pairing is reserved for
/// Welcome / splash handoff (`NightSkyView()` with default `showsMilkyWay`).
///
/// One source of truth for wizard steps that need the backdrop without owning a
/// full-bleed `ZStack` — drop it in as the first child of a step's `ZStack`,
/// or attach it with the `.onboardingBackdrop()` modifier on non-`ZStack` step
/// layouts.
///
/// The glow scales to the window via `GeometryReader` so it reads as a calm
/// atmospheric wash at any size — not a fixed-radius spotlight pinned to a
/// single layout. The accent (`chipActiveForeground`) keeps it on the §18
/// active-accent family: a deepened leaf-green in light, stamen-yellow in dark.
struct OnboardingBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            let maxDimension = max(geometry.size.width, geometry.size.height)
            ZStack {
                OhiaColors.spaceBackground
                NightSkyNebulaOverlay()
                RadialGradient(
                    colors: [
                        OhiaColors.chipActiveForeground.opacity(0.06),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: max(200, maxDimension * 0.55)
                )
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Places the shared cosmic backdrop behind a step that isn't built around
    /// a full-bleed `ZStack` (e.g. `MailSetupStepView`'s scrolling form column).
    func onboardingBackdrop() -> some View {
        background(OnboardingBackdrop())
    }
}
