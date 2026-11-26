import AppKit
import Foundation

/// Starts the embedded "Uninstall Ohia.app" in place. Before it shows a
/// window, the uninstaller copies itself to its own temporary folder and
/// relaunches from there, so it can delete Ohia.app, including its embedded
/// original, while it runs. Ohia keeps running; the uninstaller asks it to quit.
enum UninstallerLauncher {
    static func embeddedUninstallerURL(in appBundle: URL) -> URL {
        appBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("Uninstall Ohia.app", isDirectory: true)
    }

    @MainActor
    static func launch() {
        let uninstaller = embeddedUninstallerURL(in: Bundle.main.bundleURL)
        guard FileManager.default.fileExists(atPath: uninstaller.path) else {
            showFailure("The uninstaller is missing from this copy of Ohia.", detail: uninstaller.path)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--host-app", Bundle.main.bundleURL.path]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: uninstaller, configuration: configuration) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                showFailure("The uninstaller could not be opened.", detail: message)
            }
        }
    }

    @MainActor
    private static func showFailure(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
