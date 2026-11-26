import Foundation

// MARK: - System seams

/// Finds and stops running Ohia processes (the app and its services).
public protocol OhiaProcessControl: Sendable {
    func runningOhiaProcesses() -> [pid_t]
    func requestQuit() async
    func forceQuit(_ pids: [pid_t])
}

/// Launches Ohia in its uninstall-cleanup mode with `token` and reads back the
/// result it writes where `UninstallCleanupResultLocation` says. Waits while
/// the launched Ohia still runs, up to `timeout`. Returns nil when Ohia could
/// not run, exited without a result, or did not report in time.
public protocol CleanupLaunching: Sendable {
    func runCleanup(appURL: URL, token: UUID, timeout: Duration) async -> UninstallCleanupResult?
}

/// Deletes Ohia's keychain items from the uninstaller's own identity, used
/// when Ohia's cleanup did not run. Returns what could not be deleted.
public protocol KeychainSweeping: Sendable {
    func sweep(services: [String]) -> [UninstallCleanupResult.KeychainLeftover]
}

/// Resets privacy permissions at user level.
public protocol PrivacyResetting: Sendable {
    /// Resets every permission of each app. Returns the bundle IDs whose
    /// reset failed.
    func reset(bundleIDs: [String]) -> [String]
    /// Resets one app's permission to access other apps' data; false when the
    /// reset failed.
    func resetAppDataAccess(bundleID: String) -> Bool
}

/// Removes an app bundle from the Launch Services database.
public protocol AppUnregistering: Sendable {
    func unregister(_ app: URL)
}

/// Runs AppleScript that asks for an administrator password. Returns false
/// when the user cancelled or the script failed. The run never trusts the
/// answer alone: it checks every path again afterwards.
public protocol AdministratorRunning: Sendable {
    func run(appleScriptSource: String) async -> Bool
}

/// Empties preference domains in cfprefsd, synchronously. Called after the
/// domains' files are deleted: emptied first, cfprefsd writes an empty file
/// back after the delete.
public protocol PreferencesFlushing: Sendable {
    func removeDomains(_ ids: [String])
}

// MARK: - Run

public enum UninstallStep: Equatable, Sendable {
    case quittingOhia, cleaningUp, resettingPermissions, removingApp, removingData, askingAdministrator, done
}

public enum UninstallRunOutcome: Equatable, Sendable {
    /// An Ohia process was still running after the force quit, before
    /// anything was removed. Nothing was deleted.
    case ohiaStillRunning
    /// An Ohia process was still running after the force quit that followed
    /// Ohia's cleanup. The cleanup ran, so the calendar, keychain items and
    /// settings may already be removed; the result says what it reported,
    /// merged with the run's `earlierCleanup`, and is nil when neither cleanup
    /// reported back. No files were deleted, and running the uninstaller again
    /// is safe: pass this result to that run as its `earlierCleanup`.
    case ohiaStillRunningAfterCleanup(UninstallCleanupResult?)
    /// The caller's task was cancelled before anything was deleted. A cancel
    /// that arrives while waiting for Ohia to quit also skips the force quit.
    case cancelled
    case finished(UninstallReport)
}

/// Runs the uninstall in the spec's fixed order. Every system effect goes
/// through a seam; nothing is deleted while an Ohia process remains.
///
/// Cancellation is honoured only until the first step that removes something
/// (Ohia's cleanup). From there the run always finishes, because a half-done
/// uninstall is worse than a finished one.
public final class UninstallRun: Sendable {
    public static let quitPollInterval: Duration = .milliseconds(500)
    public static let quitWaitLimit: Duration = .seconds(20)
    /// How long a force-quit process gets to disappear from the process list.
    public static let forceQuitGrace: Duration = .seconds(5)
    /// How long the run waits for Ohia's cleanup while that Ohia still runs.
    /// The cleanup now empties Ohia's group container, which held 25 GB on a
    /// real Mac: a large tree of small files (the message store, the index)
    /// on a slow or nearly full disk can take minutes to delete. Half an hour
    /// leaves a wide margin; an Ohia still running after that is stuck, and
    /// the run treats its cleanup as not reported.
    public static let cleanupTimeout: Duration = .seconds(30 * 60)
    /// How long cfprefsd gets to write a preference file back before the run
    /// looks again.
    public static let preferencesSettleDelay: Duration = .seconds(1)

    private let home: URL
    private let hostApp: URL?
    private let registeredCopies: [URL]
    private let calendarWasRegistered: Bool
    private let earlierCleanup: UninstallCleanupResult?
    private let processControl: any OhiaProcessControl
    private let cleanupLauncher: any CleanupLaunching
    private let keychainSweeper: any KeychainSweeping
    private let privacyResetter: any PrivacyResetting
    private let appUnregisterer: any AppUnregistering
    private let administrator: any AdministratorRunning
    private let preferencesFlusher: any PreferencesFlushing
    private let isOhiaFromTeam: @Sendable (URL) -> Bool
    private let isWritableVolume: @Sendable (URL) -> Bool
    private let bundleVersion: @Sendable (URL) -> Int?
    private let fileExists: @Sendable (URL) -> Bool
    private let makeRemover: @Sendable () -> UninstallFileRemover
    private let makeToken: @Sendable () -> UUID
    private let sleep: @Sendable (Duration) async -> Void

    public init(
        home: URL,
        hostApp: URL?,
        registeredCopies: [URL],
        calendarWasRegistered: Bool,
        earlierCleanup: UninstallCleanupResult?,
        processControl: any OhiaProcessControl,
        cleanupLauncher: any CleanupLaunching,
        keychainSweeper: any KeychainSweeping,
        privacyResetter: any PrivacyResetting,
        appUnregisterer: any AppUnregistering,
        administrator: any AdministratorRunning,
        preferencesFlusher: any PreferencesFlushing,
        isOhiaFromTeam: @escaping @Sendable (URL) -> Bool,
        isWritableVolume: @escaping @Sendable (URL) -> Bool,
        bundleVersion: @escaping @Sendable (URL) -> Int?,
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        makeRemover: @escaping @Sendable () -> UninstallFileRemover = { UninstallFileRemover() },
        makeToken: @escaping @Sendable () -> UUID = { UUID() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.home = home
        self.hostApp = hostApp
        self.registeredCopies = registeredCopies
        self.calendarWasRegistered = calendarWasRegistered
        self.earlierCleanup = earlierCleanup
        self.processControl = processControl
        self.cleanupLauncher = cleanupLauncher
        self.keychainSweeper = keychainSweeper
        self.privacyResetter = privacyResetter
        self.appUnregisterer = appUnregisterer
        self.administrator = administrator
        self.preferencesFlusher = preferencesFlusher
        self.isOhiaFromTeam = isOhiaFromTeam
        self.isWritableVolume = isWritableVolume
        self.bundleVersion = bundleVersion
        self.fileExists = fileExists
        self.makeRemover = makeRemover
        self.makeToken = makeToken
        self.sleep = sleep
    }

    public func execute(progress: @escaping @Sendable (UninstallStep) -> Void) async -> UninstallRunOutcome {
        // 1. Quit Ohia and every service before anything is touched.
        progress(.quittingOhia)
        switch await stopOhia() {
        case .quit: break
        case .stillRunning: return .ohiaStillRunning
        case .cancelled: return .cancelled
        }

        // The last point at which the run can be called off with nothing
        // changed. Everything after it runs in a task of its own, which the
        // caller's cancellation does not reach.
        if Task.isCancelled { return .cancelled }
        return await Task { await self.removeEverything(progress: progress) }.value
    }

    /// Steps 2 to 7, from the first removal (Ohia's cleanup) to the report.
    private func removeEverything(progress: @Sendable (UninstallStep) -> Void) async -> UninstallRunOutcome {
        let selection = AppCopySelector.select(
            registered: registeredCopies, hostApp: hostApp, home: home,
            isOhiaFromTeam: isOhiaFromTeam, isWritableVolume: isWritableVolume, fileExists: fileExists)

        // 2. Clean up in Ohia's own identity, launching only a copy from our
        // team that has the cleanup mode. Ohia empties its group container,
        // which macOS lets only Ohia open, and writes its result into its own
        // container home, read here before step 5 deletes that container.
        // The cleanup launches Ohia, so confirm that process is gone too
        // before anything else is deleted.
        //
        // A sandboxed Ohia that never ran has neither its app container nor
        // its group container, so it left no data, no keychain items and no
        // calendar. Launching it then would only create both containers (and
        // a result the uninstaller could not read without a permission it
        // never needed), so the cleanup is skipped and the group container
        // counts as absent. Each is examined as itself (`lstat`), and only a
        // missing entry counts as absent.
        progress(.cleaningUp)
        let examiner = makeRemover()
        let ohiaLeftData = examiner.entryExists(OhiaUninstallCatalog.appContainerPaths(home: home)[0])
            || examiner.entryExists(OhiaUninstallCatalog.groupContainerPath(home: home))
        let cleanupApp = ohiaLeftData
            ? AppCopySelector.cleanupCandidate(
                toDelete: selection.toDelete, hostApp: hostApp,
                isOhiaFromTeam: isOhiaFromTeam, bundleVersion: bundleVersion)
            : nil
        let cleanup: UninstallCleanupResult?
        if let cleanupApp {
            cleanup = await cleanupLauncher.runCleanup(
                appURL: cleanupApp, token: makeToken(), timeout: Self.cleanupTimeout)
        } else {
            cleanup = nil
        }
        // What the cleanups of this run and of an earlier one that stopped
        // because Ohia didn't quit reported together.
        let reportedCleanup = UninstallCleanupResult.merging(cleanup, earlier: earlierCleanup)
        // Cancellation cannot reach this task, so anything but `.quit` means
        // an Ohia process may still be running.
        if await stopOhia() != .quit {
            return cleanupApp == nil ? .ohiaStillRunning : .ohiaStillRunningAfterCleanup(reportedCleanup)
        }
        let sweepLeftovers = cleanup == nil
            ? keychainSweeper.sweep(services: OhiaUninstallCatalog.keychainServices)
            : []

        // 3. Privacy permissions, at user level and while the app is still
        // registered: tccutil resolves the ID through Launch Services, and
        // macOS records the grants the helper services use under the app.
        progress(.resettingPermissions)
        let privacyResetFailed = !privacyResetter.reset(bundleIDs: [OhiaUninstallCatalog.appBundleID]).isEmpty

        // 4. App copies: each is unregistered, with the uninstaller nested in
        // it, which Launch Services records apart from the copy, then deleted.
        progress(.removingApp)
        let remover = makeRemover()
        var removals: [RemovalOutcome] = []
        for app in selection.toDelete {
            appUnregisterer.unregister(OhiaUninstallCatalog.nestedUninstallerPath(in: app))
            appUnregisterer.unregister(app)
            removals += remover.remove([app])
        }

        // 5. Data. App containers go through removeContainer, which knows
        // the file macOS keeps in each. The group container is Ohia's to
        // empty (step 2); this run empties what is left only when it can
        // open the folder (Full Disk Access), and reports the rest.
        progress(.removingData)
        let appContainers = Set(OhiaUninstallCatalog.appContainerPaths(home: home).map(\.path))
        for path in OhiaUninstallCatalog.dataPaths(home: home) {
            if appContainers.contains(path.path) {
                removals.append(remover.removeContainer(path))
            } else {
                removals += remover.remove([path])
            }
        }
        removals += groupContainerOutcomes(
            reported: ohiaLeftData ? cleanup?.groupContainer : .absent, remover: remover)
        // Then cfprefsd empties the domains, now that their files are gone:
        // emptied while the files exist, it writes them back empty a moment
        // after they are deleted. A file that comes back anyway is deleted
        // once more, and reported if it is back again.
        preferencesFlusher.removeDomains([OhiaUninstallCatalog.appBundleID, OhiaUninstallCatalog.appGroupID])
        await sleep(Self.preferencesSettleDelay)
        // A late write can also land in an app container, for example a
        // preference file Ohia's cleanup had pending. Each app container
        // counted as removed is looked at again and emptied once more if it
        // holds anything but macOS's file; what is still there is reported.
        for index in removals.indices {
            guard case .removed(let url) = removals[index], appContainers.contains(url.path),
                  remover.holdsMoreThanContainerMetadata(url)
            else { continue }
            removals[index] = remover.removeContainer(url)
        }
        let returned = OhiaUninstallCatalog.preferencePlistPaths(home: home).filter(fileExists)
        if !returned.isEmpty {
            let retried = remover.remove(returned)
            await sleep(Self.preferencesSettleDelay)
            for (plist, outcome) in zip(returned, retried) {
                let final: RemovalOutcome
                switch outcome {
                case .removed, .absent:
                    final = fileExists(plist)
                        ? .failed(plist, "macOS wrote it again after it was removed")
                        : .removed(plist)
                default:
                    final = outcome
                }
                if let index = removals.firstIndex(where: { $0.url == plist }) {
                    removals[index] = final
                } else {
                    removals.append(final)
                }
            }
        }

        // 6. One administrator prompt for the paths that failed for lack of
        // permission. Two kinds are never sent: a path in ~/Library/Containers
        // or ~/Library/Group Containers, which macOS protects from root too,
        // and a path root must not touch (its folder is not at its canonical
        // path, see AdminRemovalScript). Each is reported as such; with
        // nothing left to send there is no prompt. Whatever the prompt
        // returns, each sent path is then checked again on disk: the
        // filesystem decides what was removed.
        let blockedIndices = removals.indices.filter {
            if case .needsAdministrator = removals[$0] { return true }
            return false
        }
        var sentIndices: [Int] = []
        for index in blockedIndices {
            let url = removals[index].url
            if OhiaUninstallCatalog.isInProtectedContainerFolder(url, home: home) {
                removals[index] = .deniedByMacOS(url)
            } else if AdminRemovalScript.isRootRemovable(url) {
                sentIndices.append(index)
            } else {
                removals[index] = .folderNotWhereExpected(url)
            }
        }
        let sentPaths = sentIndices.map { removals[$0].url }
        let command = AdminRemovalScript.shellCommand(paths: sentPaths)
        if !command.isEmpty {
            progress(.askingAdministrator)
            _ = await administrator.run(appleScriptSource: AdminRemovalScript.appleScriptSource(shellCommand: command))
            for (index, outcome) in zip(sentIndices, remover.remove(sentPaths)) {
                removals[index] = outcome
            }
        }

        // The uninstaller is done with Ohia's data, so its own permission to
        // access other apps' data goes too.
        _ = privacyResetter.resetAppDataAccess(bundleID: OhiaUninstallCatalog.uninstallerBundleID)

        // 7. Report. A listed copy that is gone by now (for example, the same
        // bundle deleted under another spelling) is no longer worth listing.
        // An earlier cleanup that could not delete the calendar shows it was
        // registered, whatever this run read.
        let earlierCalendarFailed = earlierCleanup.map { $0.calendar == .failed || $0.calendar == .noAccess } ?? false
        let report = UninstallReport(
            removals: removals,
            cleanup: reportedCleanup,
            keychainSweepLeftovers: sweepLeftovers,
            privacyResetFailed: privacyResetFailed,
            otherCopies: selection.reportOnly.filter(fileExists),
            calendarWasRegistered: calendarWasRegistered || earlierCalendarFailed)
        progress(.done)
        return .finished(report)
    }

    /// What to report for Ohia's group container. macOS lets only Ohia open
    /// it, and Ohia emptied it in step 2, so its own report decides. When it
    /// did not report the container removed, the uninstaller empties it
    /// itself if it can open it (Full Disk Access) and reports each entry it
    /// still could not remove, with its own error: the Full Disk Access step
    /// would only repeat what was just tried. Otherwise it reports Ohia's
    /// entries, the container as a whole when Ohia reported it could not
    /// remove it, or that Ohia did not report. Only a missing container
    /// counts as absent; one that can't be examined is reported.
    private func groupContainerOutcomes(
        reported: UninstallCleanupResult.GroupContainerOutcome?,
        remover: UninstallFileRemover
    ) -> [RemovalOutcome] {
        let group = OhiaUninstallCatalog.groupContainerPath(home: home)
        var ohiaEntries: [UninstallCleanupResult.GroupContainerLeftover] = []
        switch reported {
        case .removed?, .absent?:
            return []
        case .leftovers(let entries)?:
            ohiaEntries = entries
        case .unreadable?, .unrecognized?, nil:
            break
        }
        guard remover.entryExists(group) else { return [] }

        if remover.canList(group) {
            switch remover.emptyGroupContainer(group) {
            case .removed, .absent:
                return []
            case .leftovers(let left):
                return left.map { entry in
                    let message = entry.errorNumber.map { String(cString: strerror($0)) }
                        ?? "it was still there after it was removed"
                    return .failed(group.appending(path: entry.name), message)
                }
            case .unreadable, .unrecognized:
                break
            }
        }

        switch reported {
        case .leftovers?:
            return ohiaEntries.isEmpty
                ? [.onlyOhiaCanRemove(group)]
                : ohiaEntries.map { .leftByOhia(group.appending(path: $0.name), errorNumber: $0.errorNumber) }
        case .unreadable?:
            return [.onlyOhiaCanRemove(group)]
        case .unrecognized?, nil, .removed?, .absent?:
            return [.ohiaDidNotReport(group)]
        }
    }

    private enum QuitResult {
        case quit, stillRunning, cancelled
    }

    /// Asks every Ohia process to quit, waits, then force-quits the rest.
    private func stopOhia() async -> QuitResult {
        guard !processControl.runningOhiaProcesses().isEmpty else { return .quit }
        await processControl.requestQuit()
        if await waitForExit(limit: Self.quitWaitLimit) { return .quit }
        // A cancelled run never force-quits.
        if Task.isCancelled { return .cancelled }
        let remaining = processControl.runningOhiaProcesses()
        guard !remaining.isEmpty else { return .quit }
        processControl.forceQuit(remaining)
        if await waitForExit(limit: Self.forceQuitGrace) { return .quit }
        return Task.isCancelled ? .cancelled : .stillRunning
    }

    /// Polls until no Ohia process remains (true), or until `limit` passes or
    /// the task is cancelled (false). Cancellation ends the wait at the next
    /// check, so sleeps that a cancel cut short never count as time waited.
    private func waitForExit(limit: Duration) async -> Bool {
        var waited = Duration.zero
        while true {
            if processControl.runningOhiaProcesses().isEmpty { return true }
            if waited >= limit || Task.isCancelled { return false }
            await sleep(Self.quitPollInterval)
            waited += Self.quitPollInterval
        }
    }
}

private extension RemovalOutcome {
    var url: URL {
        switch self {
        case .removed(let url), .absent(let url), .needsAdministrator(let url), .failed(let url, _),
             .folderNotWhereExpected(let url), .deniedByMacOS(let url), .onlyOhiaCanRemove(let url),
             .leftByOhia(let url, _), .ohiaDidNotReport(let url):
            return url
        }
    }
}
