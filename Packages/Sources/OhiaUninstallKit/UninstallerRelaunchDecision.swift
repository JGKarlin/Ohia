import Foundation

/// Whether the uninstaller first relaunches itself from a copy in its own
/// temporary folder, so it never runs from a folder the uninstall deletes
/// (started from Ohia's menu, it lives inside Ohia.app).
public enum UninstallerRelaunchDecision {
    /// Marks the relaunched copy, so it never relaunches again.
    public static let relaunchedCopyArgument = "--relaunched-copy"

    /// True unless this already is the copy, the bundle is on a read-only
    /// volume (a disk image, which nothing deletes and which needs no copy),
    /// or the executable is not inside an app bundle.
    public static func shouldRelaunch(bundleURL: URL, arguments: [String], isOnReadOnlyVolume: Bool) -> Bool {
        bundleURL.pathExtension == "app"
            && !isOnReadOnlyVolume
            && !arguments.contains(relaunchedCopyArgument)
    }

    /// The copy's launch arguments: the original ones without the executable
    /// path, plus the marker.
    public static func copyArguments(from arguments: [String]) -> [String] {
        Array(arguments.dropFirst()) + [relaunchedCopyArgument]
    }

    /// How Launch Services answered the request to open the copy.
    public enum CopyOpenOutcome: Equatable, Sendable {
        /// The copy is running.
        case opened
        /// It answered with an error, so no copy is coming.
        case failed
        /// It did not answer in time and may still start the copy.
        case unanswered
    }

    /// Only a definite failure leaves the original running. After an
    /// unanswered open the original stops, since a copy that starts late
    /// would otherwise make two uninstallers that can both start a run.
    public static func runsInPlace(after outcome: CopyOpenOutcome) -> Bool {
        outcome == .failed
    }
}
