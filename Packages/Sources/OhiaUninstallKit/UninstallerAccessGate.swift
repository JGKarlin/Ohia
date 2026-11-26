import Foundation

/// Decides, from probes of Ohia's app containers made before anything else,
/// whether the uninstaller can go on or must first get access to Ohia's data.
///
/// macOS withholds the Data folder of another app's container until the user
/// allows "access data from other apps"; the first refused attempt shows
/// that prompt. A grant applies only to processes started after it, so the
/// uninstaller relaunches itself once the user has answered. The group
/// container is not probed: macOS refuses it without a prompt to every
/// process but Ohia and those with Full Disk Access, and Ohia empties it
/// during its cleanup.
public enum UninstallerAccessGate {
    /// Marks the process started after the user answered macOS's prompt.
    public static let accessRelaunchArgument = "--access-relaunch"

    /// What opening one folder gave.
    public enum Probe: Equatable, Sendable {
        case accessible
        case absent
        /// EPERM: macOS withheld it.
        case denied
        /// Any other error number, left for the run to report.
        case failed(Int32)
    }

    public enum State: Equatable, Sendable {
        /// Go on: every app container is readable or absent.
        case ready
        /// macOS is showing its prompt; relaunch once the user has answered.
        case askToAllow
        /// The relaunched process is refused too; the user has to turn the
        /// permission on in System Settings.
        case stillDenied
    }

    public static func state(appContainerProbes: [Probe], isAccessRelaunch: Bool) -> State {
        guard appContainerProbes.contains(.denied) else { return .ready }
        return isAccessRelaunch ? .stillDenied : .askToAllow
    }

    /// One folder's probe, from its `lstat` and `opendir` error numbers
    /// (0 for success; `opendir` runs only after `lstat` succeeds). `lstat`
    /// is normally allowed where macOS withholds a container's contents, so
    /// a missing folder is told apart from a refused one; EPERM from either
    /// call counts as refused.
    public static func probe(lstatError: () -> Int32, opendirError: () -> Int32) -> Probe {
        switch lstatError() {
        case 0: break
        case ENOENT: return .absent
        case EPERM: return .denied
        case let error: return .failed(error)
        }
        switch opendirError() {
        case 0: return .accessible
        case EPERM: return .denied
        case let error: return .failed(error)
        }
    }

    public static func isAccessRelaunch(_ arguments: [String]) -> Bool {
        arguments.contains(accessRelaunchArgument)
    }

    /// The relaunched process's arguments: the current ones without the
    /// executable path, with the marker added once. A copy's own marker
    /// (`UninstallerRelaunchDecision.relaunchedCopyArgument`) stays, so the
    /// copy never copies itself again.
    public static func relaunchArguments(from arguments: [String]) -> [String] {
        let kept = Array(arguments.dropFirst())
        return kept.contains(accessRelaunchArgument) ? kept : kept + [accessRelaunchArgument]
    }
}
