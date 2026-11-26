import AppKit
import Foundation
import Observation
import OhiaUninstallKit

/// What the uninstaller was started with.
nonisolated struct UninstallerLaunch: Sendable {
    static let current = UninstallerLaunch(arguments: CommandLine.arguments)

    /// The Ohia.app whose menu started the uninstaller (`--host-app <path>`),
    /// canonicalized; nil when the path doesn't resolve to an existing folder.
    var hostApp: URL?
    /// Started again after the user answered macOS's data-access prompt
    /// (`UninstallerAccessGate.accessRelaunchArgument`).
    var isAccessRelaunch: Bool
    #if DEBUG
    /// `--probe-admin <path>`: see `AdministratorProbe`.
    var probeAdminPath: String?
    /// `--preview-finished-report`, `--preview-finished-report-long` or
    /// `--preview-running-then-finished-long`: see `UninstallerPreview`.
    var previewReport: UninstallerPreview.Variant?
    #endif

    init(arguments: [String]) {
        hostApp = UninstallerHostArgument.hostApp(from: arguments)
        isAccessRelaunch = UninstallerAccessGate.isAccessRelaunch(arguments)
        #if DEBUG
        probeAdminPath = Self.value(after: "--probe-admin", in: arguments)
        previewReport = UninstallerPreview.Variant(arguments: arguments)
        #endif
    }

    /// False only for the debug administrator probe, which runs without a window.
    var opensWindow: Bool {
        #if DEBUG
        probeAdminPath == nil
        #else
        true
        #endif
    }

    /// True only for a debug preview, which shows a sample outcome and
    /// touches nothing, so it needs no copy of itself to run from.
    var isPreview: Bool {
        #if DEBUG
        previewReport != nil
        #else
        false
        #endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.isEmpty ? nil : value
    }
}

/// The sizes the confirmation window shows.
nonisolated struct UninstallInventory: Equatable, Sendable {
    /// Total size of the Ohia.app copies that will be deleted; nil when there are none.
    var appBytes: Int64?
    var dataBytes: Int64
    /// Ohia's group container, with its mail, models and index. macOS lets
    /// only Ohia open it, so the uninstaller measures it only when it can
    /// (Full Disk Access).
    var groupContainer: UninstallSizeEstimator.GroupContainerSize
}

nonisolated struct UninstallCompletion: Equatable, Sendable {
    var report: UninstallReport
    /// The shared /Applications copy was removed while other people have
    /// accounts, and their own Ohia data, on this Mac.
    var otherAccountsKeepData: Bool
}

@Observable
final class UninstallerModel {
    enum Phase: Equatable {
        /// Probing access to Ohia's containers, before anything else.
        case checkingAccess
        /// macOS withholds Ohia's data. `stillDenied` once the relaunched
        /// process is refused too.
        case needsAccess(stillDenied: Bool)
        case confirm
        case running(UninstallStep)
        case finished(UninstallCompletion)
        case ohiaStillRunning
        /// Ohia's cleanup ran but Ohia didn't quit. `cleanupReported` is
        /// false when no cleanup has reported back.
        case ohiaStillRunningAfterCleanup(cleanupReported: Bool)
    }

    /// Where Continue's relaunch stands, in the access state.
    enum Relaunch: Equatable {
        case idle, pending, failed
    }

    private(set) var phase: Phase = .checkingAccess
    private(set) var relaunch: Relaunch = .idle
    private(set) var inventory: UninstallInventory?
    let keychainServiceCount = OhiaUninstallCatalog.keychainServices.count

    private let launch: UninstallerLaunch
    private let home: URL
    /// The run in progress. A view's task would be cancelled when the view
    /// goes away; this one belongs to the model and always finishes.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runID = 0
    /// What the cleanup of a run that stopped because Ohia didn't quit
    /// reported, handed to the next run so its report accounts for it.
    @ObservationIgnored private var earlierCleanup: UninstallCleanupResult?

    init(launch: UninstallerLaunch, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.launch = launch
        self.home = home
        #if DEBUG
        // Straight to the outcome, or to a run that turns into it: start()
        // then does nothing, so no access check, measuring or run happens.
        if let preview = launch.previewReport {
            let completion = UninstallerPreview.completion(for: preview, home: home)
            if let delay = preview.runningDelay {
                phase = .running(.removingData)
                Task {
                    try? await Task.sleep(for: delay)
                    phase = .finished(completion)
                }
            } else {
                phase = .finished(completion)
            }
        }
        #endif
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Checks access to Ohia's containers, then measures what will be
    /// removed. The probe comes first: reading a container macOS withholds
    /// makes it show its prompt, and nothing else should touch Ohia's data
    /// before the user has answered.
    func start() async {
        guard phase == .checkingAccess else { return }
        let state = await UninstallerWork.checkAccess(home: home, isAccessRelaunch: launch.isAccessRelaunch)
        guard phase == .checkingAccess else { return }
        switch state {
        case .ready:
            phase = .confirm
            await measure()
        case .askToAllow:
            phase = .needsAccess(stillDenied: false)
        case .stillDenied:
            phase = .needsAccess(stillDenied: true)
        }
    }

    /// Starts a fresh uninstaller, to which macOS applies the access the
    /// user allowed, and quits this one once it runs. While Launch Services
    /// answers, Continue is disabled; if it refuses, the window says so and
    /// Continue works again.
    func continueAfterAccess() {
        guard relaunch != .pending else { return }
        relaunch = .pending
        Task {
            if await UninstallerRelauncher.relaunchForAccess() {
                NSApp.terminate(nil)
            } else {
                relaunch = .failed
            }
        }
    }

    func openPrivacySettings() {
        UninstallerWork.openFilesAndFoldersSettings()
    }

    private func measure() async {
        guard inventory == nil else { return }
        let measured = await UninstallerWork.measure(home: home, hostApp: launch.hostApp)
        if inventory == nil {
            inventory = measured
        }
    }

    /// Starts a run from the confirmation, or again after Ohia didn't quit
    /// (Try Again). Every other phase refuses: a run never starts while
    /// access is unsettled, during a run, or over an outcome.
    func uninstall() {
        switch phase {
        case .confirm, .ohiaStillRunning, .ohiaStillRunningAfterCleanup:
            break
        case .checkingAccess, .needsAccess, .running, .finished:
            return
        }
        runID += 1
        let id = runID
        let home = home
        let hostApp = launch.hostApp
        let earlierCleanup = earlierCleanup
        phase = .running(.quittingOhia)
        runTask = Task {
            let result = await UninstallerWork.uninstall(
                home: home, hostApp: hostApp, earlierCleanup: earlierCleanup
            ) { step in
                Task { @MainActor in self.show(step, runID: id) }
            }
            self.finish(result, runID: id)
        }
    }

    private func show(_ step: UninstallStep, runID id: Int) {
        // A step reported after the run ended must not reopen it.
        guard id == runID, isRunning else { return }
        phase = .running(step)
    }

    private func finish(_ result: UninstallerWork.Result, runID id: Int) {
        guard id == runID else { return }
        runTask = nil
        switch result.outcome {
        case .finished(let report):
            earlierCleanup = nil
            phase = .finished(UninstallCompletion(report: report, otherAccountsKeepData: result.otherAccountsKeepData))
        case .ohiaStillRunning:
            phase = .ohiaStillRunning
        case .ohiaStillRunningAfterCleanup(let cleanup):
            // Already merged with the earlier result by the run.
            earlierCleanup = cleanup
            phase = .ohiaStillRunningAfterCleanup(cleanupReported: cleanup != nil)
        case .cancelled:
            phase = .confirm
        }
    }
}

/// The off-main work behind the window: sizing and the run itself.
nonisolated enum UninstallerWork {
    struct Result: Sendable {
        var outcome: UninstallRunOutcome
        var otherAccountsKeepData: Bool
    }

    static let sharedApplicationsCopy = URL(fileURLWithPath: "/Applications/Ohia.app", isDirectory: true)

    /// System Settings > Privacy & Security > Files & Folders, where macOS
    /// 27 lists the apps allowed to access other apps' data. From the
    /// Privacy & Security extension (com.apple.settings.PrivacySecurity.extension,
    /// which accepts x-apple.systempreferences URLs): the anchor
    /// Privacy_FilesAndFolders and the pane title FILE_ACCESS_COMBINED, "Files &
    /// Folders", whose summary covers "files, folders, and other app data".
    static let filesAndFoldersSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders")!

    /// Probes each existing app container's Data folder. A refused probe is
    /// what makes macOS show its "access data from other apps" prompt.
    @concurrent
    static func checkAccess(home: URL, isAccessRelaunch: Bool) async -> UninstallerAccessGate.State {
        let appProbes = OhiaUninstallCatalog.appContainerDataPaths(home: home).map(SystemLookup.probeAccess)
        return UninstallerAccessGate.state(appContainerProbes: appProbes, isAccessRelaunch: isAccessRelaunch)
    }

    @MainActor
    static func openFilesAndFoldersSettings() {
        NSWorkspace.shared.open(filesAndFoldersSettingsURL)
    }

    @concurrent
    static func measure(home: URL, hostApp: URL?) async -> UninstallInventory {
        let selection = AppCopySelector.select(
            registered: await SystemLookup.registeredOhiaCopies(),
            hostApp: hostApp,
            home: home,
            isOhiaFromTeam: SystemLookup.isOhiaFromTeam,
            isWritableVolume: SystemLookup.isWritableVolume)
        let appBytes = selection.toDelete.isEmpty
            ? nil
            : selection.toDelete.reduce(Int64(0)) { $0 + UninstallSizeEstimator.allocatedBytes(of: $1) }
        let dataBytes = OhiaUninstallCatalog.dataPaths(home: home)
            .reduce(Int64(0)) { $0 + UninstallSizeEstimator.allocatedBytes(of: $1) }
        // Opening the group container without Full Disk Access is refused
        // with EPERM and no prompt.
        let groupContainer = UninstallSizeEstimator.groupContainerSize(
            of: OhiaUninstallCatalog.groupContainerPath(home: home))
        return UninstallInventory(appBytes: appBytes, dataBytes: dataBytes, groupContainer: groupContainer)
    }

    @concurrent
    static func uninstall(
        home: URL,
        hostApp: URL?,
        earlierCleanup: UninstallCleanupResult?,
        progress: @escaping @Sendable (UninstallStep) -> Void
    ) async -> Result {
        let sharedCopyExisted = SystemLookup.entryExists(sharedApplicationsCopy)
        let run = UninstallRun(
            home: home,
            hostApp: hostApp,
            registeredCopies: await SystemLookup.registeredOhiaCopies(),
            calendarWasRegistered: SystemLookup.calendarWasRegistered(home: home),
            earlierCleanup: earlierCleanup,
            processControl: SystemProcessControl(),
            cleanupLauncher: SystemCleanupLauncher(
                home: home, temporaryDirectory: FileManager.default.temporaryDirectory),
            keychainSweeper: SystemKeychainSweeper(),
            privacyResetter: SystemPrivacyResetter(),
            appUnregisterer: SystemAppUnregisterer(),
            administrator: SystemAdministrator(),
            preferencesFlusher: SystemPreferencesFlusher(),
            isOhiaFromTeam: SystemLookup.isOhiaFromTeam,
            isWritableVolume: SystemLookup.isWritableVolume,
            bundleVersion: SystemLookup.bundleVersion)
        let outcome = await run.execute(progress: progress)
        var otherAccountsKeepData = false
        if case .finished = outcome, sharedCopyExisted, !SystemLookup.entryExists(sharedApplicationsCopy) {
            otherAccountsKeepData = SystemLookup.hasOtherUserHomes(excluding: home)
        }
        return Result(outcome: outcome, otherAccountsKeepData: otherAccountsKeepData)
    }
}
