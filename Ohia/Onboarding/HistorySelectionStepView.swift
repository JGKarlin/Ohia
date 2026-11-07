import Foundation
import SwiftUI
import OhiaCore
import OhiaMail

struct HistorySelectionStepView: View {
    enum CountPresentation: Equatable {
        case loading
        case text(String)
    }

    @Binding var selection: HistoryIngestionPreset
    let authenticatedAccountID: UUID
    let configuration: IMAPConnectionConfiguration
    let configuredAt: Date
    let controller: RemoteHistoryEstimateController
    let onContinue: () -> Void

    private var requestFingerprint: RemoteHistoryEstimateController.RequestFingerprint {
        controller.requestFingerprint(
            selection: selection,
            authenticatedAccountID: authenticatedAccountID,
            configuration: configuration,
            configuredAt: configuredAt
        )
    }

    var body: some View {
        ZStack {
            NightSkyView(showsMilkyWay: false)
            NightSkyNebulaOverlay()

            VStack(spacing: 0) {
                Spacer()

                Text("Choose email history")
                    .font(OhiaTypography.stepHeading)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.bottom, 10)

                Text("Choose how much mail Ohia should import from this account.")
                    .font(OhiaTypography.bodySecondary)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 30)

                HistoryIngestionSlider(
                    selection: $selection,
                    minimumWidening: nil,
                    caption: "Import mail history"
                )
                .frame(maxWidth: 620)

                countView
                    .frame(height: 24)
                    .padding(.top, 8)
                    .padding(.bottom, 18)

                HistoryIngestionCautionNote(variant: .full)
                    .frame(maxWidth: 620)

                Spacer()

                Button(action: onContinue) {
                    Text("Continue")
                        .font(OhiaTypography.button)
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 40, verticalPadding: 12))
                .disabled(
                    Self.canContinue(
                        afterAuthentication: true,
                        state: controller.state
                    ) == false
                )
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 48)
        }
        .task(id: requestFingerprint) {
            await controller.refresh(
                selection: selection,
                authenticatedAccountID: authenticatedAccountID,
                configuration: configuration,
                configuredAt: configuredAt
            )
        }
    }

    @ViewBuilder
    private var countView: some View {
        switch Self.countPresentation(for: controller.state) {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(OhiaColors.chipActiveForeground)
                .accessibilityLabel("Counting messages")
        case .text(let text):
            Text(text)
                .font(OhiaTypography.caption)
                .foregroundStyle(OhiaColors.textPrimary)
                .monospacedDigit()
        }
    }

    static func countPresentation(
        for state: RemoteHistoryEstimateController.State,
        locale: Locale = .current
    ) -> CountPresentation {
        switch state {
        case .idle, .loading:
            return .loading
        case .available(let count, let accuracy):
            let formattedCount = count.formatted(.number.locale(locale))
            let noun = count == 1 ? "message" : "messages"
            switch accuracy {
            case .exact:
                return .text("\(formattedCount) \(noun)")
            case .approximate:
                return .text("About \(formattedCount) \(noun)")
            }
        case .unavailable:
            return .text("Count unavailable")
        }
    }

    static func canContinue(
        afterAuthentication isAuthenticated: Bool,
        state _: RemoteHistoryEstimateController.State
    ) -> Bool {
        isAuthenticated
    }
}
