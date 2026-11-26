import Foundation

public struct AppCopySelection: Equatable {
    public var toDelete: [URL]
    public var reportOnly: [URL]

    public init(toDelete: [URL], reportOnly: [URL]) {
        self.toDelete = toDelete
        self.reportOnly = reportOnly
    }
}

/// Decides which Ohia.app copies the uninstaller deletes and which it only
/// lists. Deleted: the standard install locations, plus the app that launched
/// the uninstaller when it is verifiably Ohia from our team. Everything else
/// that Launch Services knows about is reported. Copies on read-only volumes
/// (disk images, network shares) cannot be removed and are left out entirely.
public enum AppCopySelector {
    public static func select(
        registered: [URL],
        hostApp: URL?,
        home: URL,
        isOhiaFromTeam: (URL) -> Bool,
        isWritableVolume: (URL) -> Bool,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> AppCopySelection {
        let registeredKeys = Set(registered.map(key))
        let installPaths = OhiaUninstallCatalog.appInstallPaths(home: home)
        let installKeys = Set(installPaths.map(key))

        var toDelete: [URL] = []
        var reportOnly: [URL] = []
        var seen = Set<String>()

        // Install locations first, so the deleted list keeps a stable order.
        var candidates = installPaths.filter {
            registeredKeys.contains(key($0)) || fileExists($0)
        }
        candidates += registered
        if let hostApp { candidates.append(hostApp) }

        for url in candidates {
            guard seen.insert(key(url)).inserted else { continue }
            guard isWritableVolume(url) else { continue }
            let isHost = hostApp.map { key($0) == key(url) } ?? false
            if installKeys.contains(key(url)) || (isHost && isOhiaFromTeam(url)) {
                toDelete.append(url)
            } else {
                reportOnly.append(url)
            }
        }
        return AppCopySelection(toDelete: toDelete, reportOnly: reportOnly)
    }

    /// The copy the uninstaller launches for Ohia's own cleanup, or nil when
    /// none qualifies. Candidates are the host app, when it is being deleted,
    /// then the rest of `toDelete` in order. A candidate must be Ohia from our
    /// team and a build that has the cleanup mode (its CFBundleVersion, read
    /// through `bundleVersion`, at least `firstBuildWithUninstallCleanup`).
    public static func cleanupCandidate(
        toDelete: [URL],
        hostApp: URL?,
        isOhiaFromTeam: (URL) -> Bool,
        bundleVersion: (URL) -> Int?
    ) -> URL? {
        let hostKey = hostApp.map(key)
        let host = toDelete.filter { key($0) == hostKey }
        let rest = toDelete.filter { key($0) != hostKey }
        return (host + rest).first { url in
            guard isOhiaFromTeam(url), let version = bundleVersion(url) else { return false }
            return version >= OhiaUninstallCatalog.firstBuildWithUninstallCleanup
        }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
