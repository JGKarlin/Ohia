import Foundation

/// Empties Ohia's group container: in Ohia's cleanup mode, and in the
/// uninstaller when it has Full Disk Access. macOS lets only Ohia, the
/// container's owner, and processes with Full Disk Access open it; any other
/// process is refused without a prompt.
public enum GroupContainerCleaner {
    /// Removes every entry at the root of `container` except the bookkeeping
    /// file macOS keeps there, then lists the root again and reports what is
    /// left. A link in the container's place is never followed.
    public static func empty(
        _ container: URL,
        fileSystem: any UninstallFileSystem = LocalFileSystem()
    ) -> UninstallCleanupResult.GroupContainerOutcome {
        do {
            if try fileSystem.entryIsSymbolicLink(at: container) {
                return .unreadable(errorNumber: ENOTDIR)
            }
        } catch {
            return UninstallFileRemover.isMissing(error) ? .absent : .unreadable(errorNumber: errorNumber(of: error) ?? EIO)
        }

        let names: [String]
        do {
            names = try fileSystem.contentsOfDirectory(at: container)
        } catch {
            return .unreadable(errorNumber: errorNumber(of: error) ?? EIO)
        }
        var failures: [String: Int32?] = [:]
        for name in names where name != OhiaUninstallCatalog.containerMetadataFileName {
            do {
                try fileSystem.removeItem(at: container.appending(path: name))
            } catch where !UninstallFileRemover.isMissing(error) {
                failures[name] = errorNumber(of: error)
            } catch {}
        }

        let left: [String]
        do {
            left = try fileSystem.contentsOfDirectory(at: container)
                .filter { $0 != OhiaUninstallCatalog.containerMetadataFileName }
                .sorted()
        } catch {
            return .unreadable(errorNumber: errorNumber(of: error) ?? EIO)
        }
        guard !left.isEmpty else { return .removed }
        return .leftovers(left.map {
            UninstallCleanupResult.GroupContainerLeftover(name: $0, errorNumber: failures[$0] ?? nil)
        })
    }

    /// The POSIX error number in `error` or the errors beneath it.
    static func errorNumber(of error: Error) -> Int32? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return errorNumber(of: underlying)
        }
        return nil
    }
}

/// Where Ohia's cleanup mode leaves its result for the uninstaller, which
/// without Full Disk Access can't open the group container.
public enum UninstallCleanupResultLocation {
    /// The environment variable macOS sets in every sandboxed process.
    public static let sandboxEnvironmentKey = "APP_SANDBOX_CONTAINER_ID"

    /// Sandboxed Ohia writes into its own container's home (its
    /// `homeDirectoryForCurrentUser`, ~/Library/Containers/org.jgkarlin.Ohia/Data),
    /// which the uninstaller reads once macOS allows it Ohia's data. Ohia
    /// built from source without the sandbox writes into the per-user
    /// temporary folder, the same one the uninstaller has.
    public static func directory(environment: [String: String], home: URL, temporaryDirectory: URL) -> URL {
        environment[sandboxEnvironmentKey] != nil ? home : temporaryDirectory
    }

    /// Where the uninstaller looks for the result for `token`, in order.
    public static func candidates(home: URL, temporaryDirectory: URL, token: UUID) -> [URL] {
        let name = OhiaUninstallCatalog.cleanupResultFileName(token: token)
        return [
            OhiaUninstallCatalog.appContainerDataPaths(home: home)[0].appending(path: name, directoryHint: .notDirectory),
            temporaryDirectory.appending(path: name, directoryHint: .notDirectory),
        ]
    }
}
