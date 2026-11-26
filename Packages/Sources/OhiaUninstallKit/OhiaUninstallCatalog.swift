import Foundation

/// The exact list of everything the Ohia uninstaller deletes. Paths are
/// exact; there are no wildcards.
public enum OhiaUninstallCatalog: Sendable {
    public static let appBundleID = "org.jgkarlin.Ohia"
    public static let serviceBundleIDs: [String] = [
        "org.jgkarlin.Ohia.GenerativeWorker",
        "org.jgkarlin.Ohia.MessagesReader",
        "org.jgkarlin.Ohia.PDFParser",
        "org.jgkarlin.Ohia.RetrievalWorker",
    ]
    public static let uninstallerBundleID = "org.jgkarlin.Ohia.Uninstaller"
    public static let appGroupID = "group.org.jgkarlin.Ohia"
    public static let teamID = "3T72U4Q7A5"

    public static let keychainServices: [String] = [
        "com.ohia.oauth",
        "com.ohia.smtp",
        "com.ohia.imap",
        "ohia-mcp-server-env",
        "ohia-mcp-hosted-oauth",
        "ohia-mcp-firecrawl-oauth",
    ]

    public static let calendarIdentifierDefaultsKey = "ohia.deadline.calendarIdentifier"

    /// The first CFBundleVersion with the `--uninstall-cleanup` launch mode
    /// (Ohia 0.11.0). An older Ohia would start normally instead of cleaning up.
    public static let firstBuildWithUninstallCleanup = 3

    /// App, services and app group, in the order used for per-ID folders.
    private static var allIDs: [String] { [appBundleID] + serviceBundleIDs }

    /// Everything the uninstaller itself removes. The group container is not
    /// here: macOS lets only Ohia open it, so Ohia empties it during its own
    /// cleanup (`groupContainerPath`).
    public static func dataPaths(home: URL) -> [URL] {
        appContainerPaths(home: home)
            + under("Application Scripts", allIDs + [appGroupID], home: home)
            + preferencePlistPaths(home: home)
            + under("HTTPStorages", allIDs + ["\(appBundleID).binarycookies"], home: home)
            + under("WebKit", [appBundleID], home: home)
            + under("Caches", [appBundleID], home: home)
            + under("Saved Application State", ["\(appBundleID).savedState"], home: home)
            + under("Application Support", ["Ohia"], home: home)
            + files(under: "Application Support", legacyApplicationSupportFiles, home: home)
    }

    /// Store files that earlier development builds wrote directly into
    /// ~/Library/Application Support, beside the `Ohia` folder.
    /// Current builds keep the store in the group container's private root.
    public static let legacyApplicationSupportFiles = [
        "Ohia.store",
        "Ohia.store-shm",
        "Ohia.store-wal",
        "Ohia.store.compatibility.json",
        "Ohia.sqlite",
        "Ohia.vectors.sqlite",
    ]

    /// The uninstaller nested in an Ohia copy. Launch Services registers it
    /// apart from the copy, so its record outlives the copy unless it is
    /// unregistered too.
    public static func nestedUninstallerPath(in app: URL) -> URL {
        app.appending(path: "Contents/Helpers/Uninstall Ohia.app", directoryHint: .isDirectory)
    }

    /// The sandbox containers of the app and each service.
    public static func appContainerPaths(home: URL) -> [URL] {
        under("Containers", allIDs, home: home)
    }

    /// Each app container's Data folder: what macOS's "access data from other
    /// apps" permission governs.
    public static func appContainerDataPaths(home: URL) -> [URL] {
        appContainerPaths(home: home).map { $0.appending(path: "Data", directoryHint: .isDirectory) }
    }

    /// The app group's container. For any process outside Ohia's sandbox,
    /// macOS gates it with a data-access permission it refuses without a
    /// prompt; only Ohia, its owner, can open it.
    public static func groupContainerPath(home: URL) -> URL {
        under("Group Containers", [appGroupID], home: home)[0]
    }

    /// The preference files in ~/Library/Preferences.
    public static func preferencePlistPaths(home: URL) -> [URL] {
        under("Preferences", ["\(appBundleID).plist", "\(appGroupID).plist"], home: home)
    }

    /// The file macOS keeps in every container it creates. It belongs to
    /// macOS, and nothing else can remove it.
    public static let containerMetadataFileName = ".com.apple.containermanagerd.metadata.plist"

    /// Whether `url` is inside ~/Library/Containers or ~/Library/Group
    /// Containers. macOS protects what is in them from every other process,
    /// root included, so an administrator cannot remove it either.
    public static func isInProtectedContainerFolder(_ url: URL, home: URL) -> Bool {
        let library = home.appending(path: "Library", directoryHint: .isDirectory).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return ["Containers", "Group Containers"].contains { path.hasPrefix(library + "/" + $0 + "/") }
    }

    private static func under(_ folder: String, _ names: [String], home: URL) -> [URL] {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        return names.map {
            let isFile = $0.hasSuffix(".plist") || $0.hasSuffix(".binarycookies")
            return library.appending(path: folder, directoryHint: .isDirectory)
                .appending(path: $0, directoryHint: isFile ? .notDirectory : .isDirectory)
        }
    }

    /// Exact file names in a Library folder.
    private static func files(under folder: String, _ names: [String], home: URL) -> [URL] {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        return names.map {
            library.appending(path: folder, directoryHint: .isDirectory)
                .appending(path: $0, directoryHint: .notDirectory)
        }
    }

    /// The file name Ohia's cleanup mode gives the result for `token`; where
    /// it goes is `UninstallCleanupResultLocation`.
    public static func cleanupResultFileName(token: UUID) -> String {
        "uninstall-cleanup-\(token.uuidString).json"
    }

    public static func appInstallPaths(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Ohia.app", isDirectory: true),
            home.appending(path: "Applications", directoryHint: .isDirectory)
                .appending(path: "Ohia.app", directoryHint: .isDirectory),
        ]
    }
}
