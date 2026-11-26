import AppKit
import Darwin
import OhiaUninstallKit
import SwiftUI

@main
struct OhiaUninstallerApp: App {
    @NSApplicationDelegateAdaptor(UninstallerAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Uninstall Ohia", id: "uninstaller") {
            UninstallerView(model: appDelegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(UninstallerLaunch.current.opensWindow ? .presented : .suppressed)
    }
}

/// Owns the model so the app can refuse to quit while an uninstall runs:
/// once the run has started, it is always allowed to finish.
final class UninstallerAppDelegate: NSObject, NSApplicationDelegate {
    let model = UninstallerModel(launch: .current)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window: move out of the folders the uninstall deletes.
        // The debug probe stays put, since it prints to the terminal that
        // started it and deletes nothing it runs from, and so does a debug
        // preview, which deletes nothing at all.
        if UninstallerLaunch.current.opensWindow, !UninstallerLaunch.current.isPreview {
            UninstallerRelauncher.relaunchIfNeeded()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let path = UninstallerLaunch.current.probeAdminPath {
            Task {
                exit(await AdministratorProbe.run(path: path))
            }
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.isRunning ? .terminateCancel : .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

#if DEBUG
/// Debug-only proof that the administrator step works under the hardened
/// runtime. `--probe-admin <path>` removes one existing regular file directly
/// inside /private/tmp (created with `sudo touch`, so only an administrator
/// can remove it) through the same seam and script the uninstall uses, prints
/// the outcome and exits: 0 removed, 1 not removed, 2 refused.
nonisolated enum AdministratorProbe {
    static func run(path: String) async -> Int32 {
        guard let target = target(for: path) else {
            report("refused \(path): give an existing regular file directly inside /private/tmp")
            return 2
        }
        let command = AdminRemovalScript.shellCommand(paths: [target])
        let accepted = await SystemAdministrator().run(
            appleScriptSource: AdminRemovalScript.appleScriptSource(shellCommand: command))
        let removed = !SystemLookup.entryExists(target)
        report("administrator step \(accepted ? "succeeded" : "failed or was cancelled"); "
            + "\(target.path) \(removed ? "was removed" : "is still there")")
        return accepted && removed ? 0 : 1
    }

    private static func target(for path: String) -> URL? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let full = String(cString: resolved)
        let directory = "/private/tmp/"
        guard full.hasPrefix(directory), !full.dropFirst(directory.count).contains("/") else { return nil }
        return URL(fileURLWithPath: full, isDirectory: false)
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data("probe-admin: \(line)\n".utf8))
    }
}
#endif
