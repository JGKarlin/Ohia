#if DEBUG
import Foundation
import OhiaUninstallKit

/// Debug-only sample outcomes, so the finished window can be looked at
/// without running an uninstall. Each report is built by `UninstallReport`
/// itself, so its wording is the real wording. Nothing here reads or changes
/// anything on disk.
nonisolated enum UninstallerPreview {
    enum Variant: Equatable, Sendable {
        /// `--preview-finished-report`: what the live end-to-end run reported.
        case finishedReport
        /// `--preview-finished-report-long`: twelve leftovers and three other
        /// copies, enough to reach the window's height cap.
        case longFinishedReport
        /// `--preview-running-then-finished-long`: the running state for about
        /// two seconds, then the long report, so the window is seen growing
        /// from its 420-point size.
        case runningThenFinishedLong

        static let finishedReportArgument = "--preview-finished-report"
        static let longFinishedReportArgument = "--preview-finished-report-long"
        static let runningThenFinishedLongArgument = "--preview-running-then-finished-long"

        /// How long the preview shows the running state first; nil to open on
        /// the outcome.
        var runningDelay: Duration? {
            self == .runningThenFinishedLong ? .seconds(2) : nil
        }

        init?(arguments: [String]) {
            if arguments.contains(Self.runningThenFinishedLongArgument) {
                self = .runningThenFinishedLong
            } else if arguments.contains(Self.longFinishedReportArgument) {
                self = .longFinishedReport
            } else if arguments.contains(Self.finishedReportArgument) {
                self = .finishedReport
            } else {
                return nil
            }
        }
    }

    static func completion(for variant: Variant, home: URL) -> UninstallCompletion {
        switch variant {
        case .finishedReport: finishedReport(home: home)
        case .longFinishedReport, .runningThenFinishedLong: longFinishedReport(home: home)
        }
    }

    /// Two keychain services Ohia could not empty and one other copy left in
    /// place.
    private static func finishedReport(home: URL) -> UninstallCompletion {
        let report = UninstallReport(
            removals: [],
            cleanup: UninstallCleanupResult(
                calendar: .notRegistered,
                keychainLeftovers: [
                    .init(service: "com.ohia.oauth", count: 65),
                    .init(service: "com.ohia.smtp", count: 223),
                ]),
            otherCopies: [URL(fileURLWithPath: "/Volumes/Backup/Applications/Ohia.app", isDirectory: true)],
            calendarWasRegistered: false)
        return UninstallCompletion(report: report, otherAccountsKeepData: false)
    }

    private static func longFinishedReport(home: URL) -> UninstallCompletion {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        let group = OhiaUninstallCatalog.groupContainerPath(home: home)
        let report = UninstallReport(
            removals: [
                .needsAdministrator(URL(fileURLWithPath: "/Applications/Ohia.app", isDirectory: true)),
                .deniedByMacOS(library.appending(path: "Containers/org.jgkarlin.Ohia.GenerativeWorker")),
                .leftByOhia(group.appending(path: "private-state"), errorNumber: EPERM),
                .leftByOhia(group.appending(path: "public-models"), errorNumber: nil),
                .failed(library.appending(path: "Caches/org.jgkarlin.Ohia"), "Resource busy"),
                .failed(
                    library.appending(path: "Preferences/org.jgkarlin.Ohia.plist"),
                    "macOS wrote it again after it was removed"),
                .folderNotWhereExpected(library.appending(path: "HTTPStorages/org.jgkarlin.Ohia")),
                .needsAdministrator(library.appending(path: "Application Support/Ohia.store")),
            ],
            cleanup: UninstallCleanupResult(
                calendar: .failed,
                calendarError: "The calendar is read-only.",
                keychainLeftovers: [
                    .init(service: "com.ohia.oauth", count: 65),
                    .init(service: "com.ohia.smtp", count: 223),
                ]),
            privacyResetFailed: true,
            otherCopies: [
                URL(fileURLWithPath: "/Volumes/Backup/Applications/Ohia.app", isDirectory: true),
                home.appending(path: "Downloads/Ohia 0.10.0/Ohia.app", directoryHint: .isDirectory),
                URL(fileURLWithPath: "/Users/Shared/Ohia.app", isDirectory: true),
            ],
            calendarWasRegistered: true)
        return UninstallCompletion(report: report, otherAccountsKeepData: true)
    }
}
#endif
