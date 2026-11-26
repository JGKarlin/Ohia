import Darwin
import Foundation
import OhiaCore
import OhiaUninstallKit

/// Headless launch mode the uninstaller starts after quitting Ohia. Ohia owns
/// its keychain items, its Calendar permission and its group container (macOS
/// lets only Ohia open that container), so it removes them itself, writes a
/// small JSON result where the uninstaller can read it, and exits.
enum UninstallCleanupMode {
    static let failureExitCode: Int32 = 1

    /// The cleanup in its fixed order: the calendar, the keychain, pending
    /// preference writes flushed to disk (so cfprefsd has nothing left to
    /// write after the files are gone), then the group container emptied.
    /// Nothing here resets preferences: an emptied domain is written back
    /// later, and the files go with the containers anyway.
    static func run(
        deleteCalendar: () throws -> UninstallCleanupResult.CalendarOutcome,
        sweepKeychain: () -> [DeveloperCredentialResetter.Leftover],
        flushDefaults: () -> Void,
        emptyGroupContainer: () -> UninstallCleanupResult.GroupContainerOutcome
    ) -> UninstallCleanupResult {
        var calendar = UninstallCleanupResult.CalendarOutcome.deleted
        var calendarError: String?
        do {
            calendar = try deleteCalendar()
        } catch DeadlineCalendarSyncError.permissionRequired {
            calendar = .noAccess
        } catch {
            calendar = .failed
            calendarError = error.localizedDescription
        }
        let leftovers = sweepKeychain().map {
            UninstallCleanupResult.KeychainLeftover(service: $0.service, count: $0.count)
        }
        flushDefaults()
        let groupContainer = emptyGroupContainer()
        return UninstallCleanupResult(
            calendar: calendar,
            calendarError: calendarError,
            keychainLeftovers: leftovers,
            groupContainer: groupContainer
        )
    }

    static func perform(resultToken: UUID) -> Never {
        let result = run(
            deleteCalendar: {
                guard DeadlineCalendarSync.hasManagedCalendarRegistration else {
                    return .notRegistered
                }
                try DeadlineCalendarSync.deleteManagedCalendar()
                return .deleted
            },
            sweepKeychain: { DeveloperCredentialResetter.resetAll() },
            flushDefaults: {
                UserDefaults.standard.synchronize()
                OhiaSharedDefaults.store.synchronize()
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            },
            emptyGroupContainer: {
                // The App Group is in Ohia's entitlements; without it this
                // build cannot reach the container at all.
                guard let container = try? OhiaStorageRoot.resolve().containerRoot else {
                    return .unreadable(errorNumber: EPERM)
                }
                return GroupContainerCleaner.empty(container)
            }
        )
        do {
            let directory = UninstallCleanupResultLocation.directory(
                environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser,
                temporaryDirectory: FileManager.default.temporaryDirectory
            )
            let url = directory.appendingPathComponent(
                OhiaUninstallCatalog.cleanupResultFileName(token: resultToken),
                isDirectory: false
            )
            try JSONEncoder().encode(result).write(to: url, options: .atomic)
        } catch {
            exit(failureExitCode)
        }
        exit(0)
    }
}
