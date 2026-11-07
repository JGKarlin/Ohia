import SwiftUI
import AppKit
import OhiaCore
import OhiaML

struct AppleIntelligenceStepPresentation: Equatable {
    enum Action: Equatable {
        case continueWithApple
        case openSettings
    }

    let icon: String
    let title: String
    let message: String
    let instructions: [String]
    let primaryTitle: String
    let primaryIcon: String
    let primaryAction: Action
    let secondaryTitle: String?
    let secondaryIcon: String?
    let secondaryAction: Action?
    let footnote: String

    static func make(for availability: AppleIntelligenceAvailability.State) -> Self {
        switch availability {
        case .available:
            return Self(
                icon: "checkmark.circle.fill",
                title: "Apple Intelligence Ready",
                message: "Apple Intelligence summarizes image attachments on-device. Email text uses your local Qwen model.",
                instructions: [],
                primaryTitle: "Continue",
                primaryIcon: "arrow.right",
                primaryAction: .continueWithApple,
                secondaryTitle: nil,
                secondaryIcon: nil,
                secondaryAction: nil,
                footnote: "Apple Intelligence is required for image-attachment summaries; for email text it's a fallback used only when Qwen returns no summary."
            )
        case .appleIntelligenceNotEnabled:
            return Self(
                icon: "sparkle.magnifyingglass",
                title: "Apple Intelligence Required",
                message: "Ohia requires Apple Intelligence for concise on-hover summaries, including image attachments.",
                instructions: [
                    "Click \"Open System Settings\" below",
                    "Turn on Apple Intelligence",
                    "Ohia continues on its own"
                ],
                primaryTitle: "Open System Settings",
                primaryIcon: "gear",
                primaryAction: .openSettings,
                secondaryTitle: nil,
                secondaryIcon: nil,
                secondaryAction: nil,
                footnote: "Onboarding continues the moment it's ready."
            )
        case .deviceNotEligible:
            return unavailable(
                message: "This Mac must support Apple Intelligence before Ohia can enable summarization.",
                footnote: "Apple Intelligence is not available on this Mac."
            )
        case .modelNotReady:
            return unavailable(
                message: "Apple Intelligence is turned on, but the local model is not ready yet.",
                footnote: "Ohia continues automatically once the model finishes preparing."
            )
        case .unknown:
            return unavailable(
                message: "Ohia could not confirm Apple Intelligence availability on this Mac.",
                footnote: "Ohia keeps checking and continues the moment it's confirmed."
            )
        }
    }

    private static func unavailable(message: String, footnote: String) -> Self {
        Self(
            icon: "exclamationmark.triangle.fill",
            title: "Apple Intelligence Required",
            message: message,
            instructions: [],
            primaryTitle: "Open System Settings",
            primaryIcon: "gear",
            primaryAction: .openSettings,
            secondaryTitle: nil,
            secondaryIcon: nil,
            secondaryAction: nil,
            footnote: footnote
        )
    }
}

struct AppleIntelligenceStepView: View {
    let onContinue: () -> Void
    private let refreshesAvailability: Bool
    private let availabilityProvider: () -> AppleIntelligenceAvailability.State

    @AppStorage("summarizationUseAppleIntelligence", store: OhiaSharedDefaults.store)
    private var useAppleIntelligence = true
    @State private var availability: AppleIntelligenceAvailability.State = .unknown
    // Latches once the step has advanced, so neither the background poll nor the
    // app-reactivation re-check can call `onContinue()` a second time.
    @State private var hasAdvanced = false

    init(
        onContinue: @escaping () -> Void,
        initialAvailability: AppleIntelligenceAvailability.State = .unknown,
        refreshesAvailability: Bool = true,
        availabilityProvider: @escaping () -> AppleIntelligenceAvailability.State = { AppleIntelligenceAvailability.current() }
    ) {
        self.onContinue = onContinue
        self.refreshesAvailability = refreshesAvailability
        self.availabilityProvider = availabilityProvider
        _availability = State(initialValue: initialAvailability)
    }

    private var presentation: AppleIntelligenceStepPresentation {
        AppleIntelligenceStepPresentation.make(for: availability)
    }

    var body: some View {
        ZStack {
            NightSkyView(showsMilkyWay: false)
            NightSkyNebulaOverlay()

            VStack(spacing: 0) {
                Spacer()

                Image(systemName: presentation.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(iconColor)
                    .padding(.bottom, 16)

                Text(presentation.title)
                    .font(OhiaTypography.stepHeading)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.bottom, 8)

                Text(presentation.message)
                    .font(OhiaTypography.body)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 440)
                    .padding(.bottom, presentation.instructions.isEmpty ? 26 : 30)

                if presentation.instructions.isEmpty == false {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(presentation.instructions.enumerated()), id: \.offset) { index, text in
                            instructionRow(step: "\(index + 1)", text: text)
                        }
                    }
                    .padding(20)
                    .background(OhiaColors.settingsCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OhiaColors.glassBorder, lineWidth: 1)
                    )
                    .frame(maxWidth: 400)
                    .padding(.bottom, 24)
                }

                HStack(spacing: 16) {
                    Button {
                        perform(presentation.primaryAction)
                    } label: {
                        Label(presentation.primaryTitle, systemImage: presentation.primaryIcon)
                            .font(OhiaTypography.button)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 20, verticalPadding: 10))
                    .accessibilityLabel(presentation.primaryTitle)

                    if let secondaryTitle = presentation.secondaryTitle,
                       let secondaryIcon = presentation.secondaryIcon,
                       let secondaryAction = presentation.secondaryAction {
                        Button {
                            perform(secondaryAction)
                        } label: {
                            Label(secondaryTitle, systemImage: secondaryIcon)
                                .font(OhiaTypography.button)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(EmblemButtonStyle(horizontalPadding: 20, verticalPadding: 10))
                        .accessibilityLabel(secondaryTitle)
                    }
                }
                .padding(.bottom, isWaiting ? 16 : 32)

                if isWaiting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(OhiaColors.chipActiveForeground)
                        Text("Waiting for Apple Intelligence")
                            .font(OhiaTypography.body)
                            .foregroundStyle(OhiaColors.textPrimary)
                    }
                    .padding(.bottom, 18)
                }

                Text(presentation.footnote)
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)

                Spacer()
            }
            .padding(.horizontal, 48)
        }
        .task {
            guard refreshesAvailability else { return }
            // Poll Apple Intelligence availability in the background and advance
            // the instant it's authorized and the local model is ready — no
            // manual "Check Again" press. `refreshAvailability()` advances when
            // available and latches via `hasAdvanced`, so it can never advance
            // twice. The loop exits cleanly on cancellation (when the step
            // disappears) — a bare `try?` would swallow `CancellationError` and
            // let the body run one more time. `deviceNotEligible` can never
            // resolve by waiting, so stop polling there (its footnote conveys
            // the dead end).
            while !Task.isCancelled {
                if refreshAvailability() { break }
                if availability == .deviceNotEligible { break }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check immediately on return from System Settings so enabling
            // Apple Intelligence advances without waiting for the next poll tick.
            guard refreshesAvailability else { return }
            refreshAvailability()
        }
    }

    private var iconColor: Color {
        // Ready is the one success moment on this step → leaf green; every
        // other (required / waiting / ineligible) state is informational, so
        // it stays a calm neutral rather than an alarming red.
        availability == .available ? OhiaColors.ohiaGreen : OhiaColors.textSecondary
    }

    // The step monitors availability automatically; show the live "waiting"
    // affordance whenever a not-yet-available state could still resolve by
    // waiting. `deviceNotEligible` never will, so it shows no spinner.
    private var isWaiting: Bool {
        Self.showsWaitingIndicator(
            refreshesAvailability: refreshesAvailability,
            availability: availability
        )
    }

    /// Whether the live "waiting" affordance should show: the step is actively
    /// polling, Apple Intelligence is not yet available, and the state can still
    /// resolve by waiting. `deviceNotEligible` never will, so it shows nothing.
    static func showsWaitingIndicator(
        refreshesAvailability: Bool,
        availability: AppleIntelligenceAvailability.State
    ) -> Bool {
        refreshesAvailability
            && !availability.isAvailable
            && availability != .deviceNotEligible
    }

    private func instructionRow(step: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .frame(width: 20, height: 20)
                .background(OhiaColors.chipActiveBackground)
                .clipShape(Circle())

            Text(text)
                .font(OhiaTypography.body)
                .foregroundStyle(OhiaColors.textPrimary)
        }
    }

    private func perform(_ action: AppleIntelligenceStepPresentation.Action) {
        switch action {
        case .continueWithApple:
            useAppleIntelligence = true
            onContinue()
        case .openSettings:
            openAppleIntelligenceSettings()
        }
    }

    /// Re-reads availability and advances when Apple Intelligence is ready.
    /// Returns `true` once available (and after advancing) so the background
    /// poll loop can stop.
    @discardableResult
    private func refreshAvailability() -> Bool {
        guard !hasAdvanced else { return true }
        let refreshedAvailability = availabilityProvider()
        availability = refreshedAvailability
        guard refreshedAvailability.isAvailable else {
            return false
        }
        hasAdvanced = true
        useAppleIntelligence = true
        onContinue()
        return true
    }

    private func openAppleIntelligenceSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Apple-Intelligence-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.assistant"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }
}
