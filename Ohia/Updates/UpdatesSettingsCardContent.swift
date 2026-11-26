import SwiftUI

/// The Updates card, bound to the app's update controller.
struct UpdatesSettingsCardContent: View {
    @Bindable var controller: OhiaUpdateController

    var body: some View {
        OhiaSettingsCard("Updates") {
            SettingsRow("Check for updates automatically") {
                Toggle("", isOn: $controller.automaticallyChecksForUpdates)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsRow("Download and install updates automatically") {
                Toggle("", isOn: $controller.automaticallyDownloadsUpdates)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.automaticallyChecksForUpdates)
            }
            SettingsRowDivider()
            SettingsCaption(Self.caption(lastChecked: controller.lastUpdateCheckDate))
            SettingsRowDivider()
            SettingsBlock {
                HStack {
                    Spacer(minLength: 0)
                    Button("Check Now", action: controller.checkForUpdates)
                        .buttonStyle(.emblem)
                        .disabled(!controller.canCheckForUpdates)
                }
            }
        }
    }

    private static func caption(lastChecked: Date?) -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let checked: String
        if let lastChecked {
            checked = "Last checked " + lastChecked.formatted(.relative(presentation: .named))
        } else {
            checked = "Not checked yet"
        }
        return "Version \(short) (\(build)) · \(checked)"
    }
}
