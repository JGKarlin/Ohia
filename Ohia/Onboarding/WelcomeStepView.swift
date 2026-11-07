import SwiftUI

struct WelcomeStepView: View {
    let onContinue: () -> Void

    @State private var tagline = OhiaTaglines.random
    @SwiftUI.FocusState private var keyInputFocused: Bool

    var body: some View {
        ZStack {
            // Start screen rides the same deterministic night sky as the
            // splash (SplashView), so the splash → welcome handoff has no
            // visible jump in star *position* — Milky Way band, no shooting
            // star, same as the splash. The twinkle itself switches to
            // `.vivid` here: wider, more varied per-star brightness swings
            // plus a subtle hue drift, since this is the screen the user
            // actually lingers on with the Get Started button. Other
            // onboarding steps keep OnboardingBackdrop.
            NightSkyView(starIntensity: .vivid)

            VStack(spacing: 0) {
                Spacer()

                // App icon — ʻōhiʻa lehua flower
                Image("ohia")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .padding(.bottom, 8)

                // Title
                Text("Ohia")
                    .font(OhiaTypography.appTitle)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.bottom, 16)

                // Tagline
                Text(tagline)
                    .font(OhiaTypography.body)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.bottom, 48)

                // Get Started button
                Button(action: onContinue) {
                    Text("Get Started")
                        .font(OhiaTypography.button)
                        .foregroundStyle(OhiaColors.ohiaGreen)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(OhiaColors.buttonBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Ontological Hypergraph of Intelligent Associations\n(Ohia Hates Inbox Architecture)")
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 6)

                // Copyright
                Text("© 2026 Jason G. Karlin")
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 48)
        }
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($keyInputFocused)
        .onKeyPress(.return) {
            onContinue()
            return .handled
        }
        .onAppear {
            keyInputFocused = true
        }
    }
}
