import AppKit
import Darwin
import Foundation
import LocalAuthentication
import OhiaUninstallKit
import Security

// The concrete system effects behind UninstallRun's seams. UninstallRun calls
// them off the main actor; AppKit work hops to the main actor.

// MARK: - Processes

/// Finds and stops Ohia, its XPC services and a Sparkle install of an Ohia
/// update for the current user. XPC services and Sparkle's installer tools
/// are not NSRunningApplications, so they are found by executable path
/// through libproc. The uninstaller never matches itself.
nonisolated struct SystemProcessControl: OhiaProcessControl {
    static let serviceExecutableSuffixes: [String] = [
        "OhiaGenerativeWorker", "OhiaMessagesReader", "OhiaPDFParser", "OhiaRetrievalWorker",
    ].map { "/Contents/XPCServices/\($0).xpc/Contents/MacOS/\($0)" }

    func runningOhiaProcesses() -> [pid_t] {
        let apps = Self.runningApps().map(\.processIdentifier)
        let helpers = Self.allProcessIDs().filter(Self.isOhiaHelper)
        return Array(Set(apps + helpers)).sorted()
    }

    func requestQuit() async {
        await MainActor.run {
            for app in Self.runningApps() {
                app.terminate()
            }
        }
    }

    func forceQuit(_ pids: [pid_t]) {
        let apps = Self.runningApps().filter { pids.contains($0.processIdentifier) }
        let appPIDs = Set(apps.map(\.processIdentifier))
        // Each helper pid is re-checked just before the signal, in case its
        // process exited and the pid was reused since the listing. An
        // installer running as root refuses the signal and is waited out.
        for pid in pids where !appPIDs.contains(pid) && Self.isOhiaHelper(pid) {
            kill(pid, SIGKILL)
        }
        guard !apps.isEmpty else { return }
        Task { @MainActor in
            for app in apps {
                app.forceTerminate()
            }
        }
    }

    private static func runningApps() -> [NSRunningApplication] {
        let ownPID = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: OhiaUninstallCatalog.appBundleID)
            .filter { !$0.isTerminated && $0.processIdentifier > 0 && $0.processIdentifier != ownPID }
    }

    /// An XPC service of any Ohia copy, run by the current user, or one of
    /// Sparkle's installer tools inside an Ohia copy (see
    /// SparkleInstallerProcess), run by the current user or, for an update
    /// that needed an administrator, by root in the system domain. Another
    /// account's Ohia is not this uninstall's business and can't be stopped.
    private static func isOhiaHelper(_ pid: pid_t) -> Bool {
        guard pid > 0, pid != getpid(), let owner = owner(of: pid), let path = executablePath(of: pid) else {
            return false
        }
        if serviceExecutableSuffixes.contains(where: { path.hasSuffix($0) }) {
            return owner == getuid()
        }
        if let app = SparkleInstallerProcess.hostApp(ofExecutablePath: path) {
            return (owner == getuid() || owner == 0)
                && SystemLookup.bundleIdentifier(of: URL(fileURLWithPath: app, isDirectory: true))
                    == OhiaUninstallCatalog.appBundleID
        }
        return false
    }

    private static func allProcessIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func owner(of pid: pid_t) -> uid_t? {
        // The short form: the kernel answers PROC_PIDTBSDINFO only for the
        // caller's own processes, so a root-owned installer would go unmatched.
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }
}

// MARK: - Ohia's own cleanup

/// Opens Ohia in its uninstall-cleanup mode and reads the result it writes
/// into its container home (or, built without the sandbox, the temporary
/// folder); see `UninstallCleanupResultLocation`.
nonisolated struct SystemCleanupLauncher: CleanupLaunching {
    let home: URL
    let temporaryDirectory: URL

    /// Launches Ohia, then leaves the waiting to `CleanupResultPoller`: up to
    /// `timeout` while that Ohia (or, when Launch Services reported an error,
    /// any Ohia process) runs, `openErrorGrace` otherwise, the result read and
    /// deleted from the first place it is found.
    func runCleanup(appURL: URL, token: UUID, timeout: Duration) async -> UninstallCleanupResult? {
        let candidates = UninstallCleanupResultLocation.candidates(
            home: home, temporaryDirectory: temporaryDirectory, token: token)
        let app = await Self.open(appURL, token: token)
        let start = ContinuousClock.now
        let poller = CleanupResultPoller(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            read: { try? Data(contentsOf: $0) },
            remove: { try? FileManager.default.removeItem(at: $0) },
            elapsed: { ContinuousClock.now - start },
            sleep: { try await Task.sleep(for: $0) })
        let processes = SystemProcessControl()
        return await poller.wait(
            for: candidates,
            launched: app != nil,
            hasExited: { app?.isTerminated ?? true },
            ohiaIsRunning: { !processes.runningOhiaProcesses().isEmpty },
            timeout: timeout)
    }

    /// The running cleanup instance, or nil when Launch Services reported an error.
    @MainActor
    private static func open(_ appURL: URL, token: UUID) async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--uninstall-cleanup", "--result-token", token.uuidString]
        return try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

// MARK: - Keychain

/// Deletes Ohia's generic-password items when Ohia's own cleanup did not run.
/// Each item is deleted by reference, since a bulk delete on the file-based
/// keychain removes only the first match. Every query disallows user
/// interaction, so an item that would need a prompt is counted as left over.
nonisolated struct SystemKeychainSweeper: KeychainSweeping {
    func sweep(services: [String]) -> [UninstallCleanupResult.KeychainLeftover] {
        services.compactMap { service in
            let remaining = Self.sweep(service: service)
            return remaining > 0 ? UninstallCleanupResult.KeychainLeftover(service: service, count: remaining) : nil
        }
    }

    private static func sweep(service: String) -> Int {
        // Without a service the query would match every generic password.
        guard !service.isEmpty else { return 0 }
        var matches: CFTypeRef?
        let listing = SecItemCopyMatching(withoutInteraction([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]), &matches)
        switch listing {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return 0
        default:
            return remainingCount(service: service)
        }
        let items: [AnyObject]
        if let array = matches as? [AnyObject] {
            items = array
        } else if let single = matches {
            items = [single]
        } else {
            items = []
        }
        var remaining = 0
        for item in items {
            let status = SecItemDelete(withoutInteraction([
                kSecClass as String: kSecClassGenericPassword,
                kSecMatchItemList as String: [item],
            ]))
            if status != errSecSuccess && status != errSecItemNotFound {
                remaining += 1
            }
        }
        return remaining
    }

    /// An unreadable keychain counts as one item left, since none can be shown to be gone.
    private static func remainingCount(service: String) -> Int {
        var matches: CFTypeRef?
        let status = SecItemCopyMatching(withoutInteraction([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]), &matches)
        switch status {
        case errSecSuccess:
            return max((matches as? [Any])?.count ?? 1, 1)
        case errSecItemNotFound:
            return 0
        default:
            return 1
        }
    }

    private static func withoutInteraction(_ query: [String: Any]) -> CFDictionary {
        let context = LAContext()
        context.interactionNotAllowed = true
        var copy = query
        copy[kSecUseAuthenticationContext as String] = context
        return copy as CFDictionary
    }
}

// MARK: - Privacy, Launch Services, administrator, preferences

nonisolated struct SystemPrivacyResetter: PrivacyResetting {
    func reset(bundleIDs: [String]) -> [String] {
        // An empty identifier would make tccutil reset every app's
        // permissions; there is nothing to reset for one, so it is skipped.
        bundleIDs.filter { !$0.isEmpty && !$0.hasPrefix("-") }
            .filter { !SystemCommand.run("/usr/bin/tccutil", ["reset", "All", $0]) }
    }

    func resetAppDataAccess(bundleID: String) -> Bool {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("-") else { return false }
        return SystemCommand.run("/usr/bin/tccutil", ["reset", "SystemPolicyAppData", bundleID])
    }
}

nonisolated struct SystemAppUnregisterer: AppUnregistering {
    static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    func unregister(_ app: URL) {
        // Only ever an absolute bundle path: lsregister's other arguments
        // rebuild or delete the whole Launch Services database.
        let path = app.standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/" else { return }
        _ = SystemCommand.run(Self.lsregister, ["-u", path])
    }
}

/// Runs the one administrator command on the main actor: NSAppleScript is
/// not thread-safe, and from the main thread the password prompt names
/// "Uninstall Ohia".
nonisolated struct SystemAdministrator: AdministratorRunning {
    func run(appleScriptSource: String) async -> Bool {
        await MainActor.run {
            guard let script = NSAppleScript(source: appleScriptSource) else { return false }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
            return error == nil
        }
    }
}

/// Empties each domain in cfprefsd and waits for it to take the change.
/// There is no `UserDefaults.removePersistentDomain(forName:)`: it writes an
/// empty domain back asynchronously, which recreated the deleted plists as
/// empty files.
nonisolated struct SystemPreferencesFlusher: PreferencesFlushing {
    func removeDomains(_ ids: [String]) {
        for id in ids where !id.isEmpty {
            let domain = id as CFString
            if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
               CFArrayGetCount(keys) > 0 {
                CFPreferencesSetMultiple(nil, keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }
}

nonisolated enum SystemCommand {
    /// Runs a tool with no input or output; true when it exits with status 0.
    static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable, isDirectory: false)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
