import Darwin
import Foundation

/// Builds the one command the uninstaller runs with administrator rights for
/// the few removals that need them. Every interpolated value is wrapped in
/// single quotes (the only shell quoting that is inert for every character
/// but the quote itself) and then escaped again for an AppleScript literal.
public enum AdminRemovalScript {
    /// One subshell per path, joined with ` ; ` so a failure never skips the
    /// paths after it. Each subshell changes into the path's parent without
    /// following links, confirms it arrived in exactly that folder, and only
    /// then removes the last component, so a parent swapped for a link after
    /// the check is never followed. A path whose parent is not absolute and
    /// canonical, or whose last component is empty, `.` or `..`, is left out
    /// and never reaches root. The exit status says nothing: the caller checks
    /// every path on disk afterwards.
    public static func shellCommand(paths: [URL]) -> String {
        paths.compactMap { url in
            guard let parts = rootRemovableParts(url.path) else { return nil }
            let parent = quote(parts.parent)
            return "( cd -P -- \(parent) && [ \"$(pwd -P)\" = \(parent) ] && rm -rf -- \(quote(parts.name)) )"
        }
        .joined(separator: " ; ")
    }

    /// Whether `shellCommand(paths:)` sends `url` to root.
    public static func isRootRemovable(_ url: URL) -> Bool {
        rootRemovableParts(url.path) != nil
    }

    public static func appleScriptSource(shellCommand: String) -> String {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// Splits `path` into its parent and last component when root may remove
    /// it: the parent is absolute and canonical (`realpath` gives it back
    /// unchanged, so it has no link, `.` or `..` in it) and the last component
    /// is a real entry name.
    static func rootRemovableParts(_ path: String) -> (parent: String, name: String)? {
        guard path.hasPrefix("/"), let slash = path.lastIndex(of: "/") else { return nil }
        let name = String(path[path.index(after: slash)...])
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        // Compared as bytes, as the shell's `[ "$(pwd -P)" = <parent> ]` test compares them:
        // Swift's String equality treats composed and decomposed Unicode as equal.
        guard !name.isEmpty, name != ".", name != "..",
              let canonical = canonicalPath(of: parent), Array(canonical.utf8) == Array(parent.utf8)
        else { return nil }
        return (parent, name)
    }

    private static func canonicalPath(of path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
