import Darwin
import Foundation

/// Reads `--host-app <path>`, the Ohia.app whose menu started the uninstaller.
public enum UninstallerHostArgument {
    public static let flag = "--host-app"

    /// The host app's canonical path (`realpath`: no symbolic link, `.` or
    /// `..`), so it matches the copies the uninstaller finds under their real
    /// paths. Nil when the flag or its value is missing, the value is not an
    /// absolute path, or it does not resolve to an existing folder.
    public static func hostApp(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        guard value.hasPrefix("/"), let resolved = realpath(value, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
