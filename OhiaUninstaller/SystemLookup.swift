import AppKit
import Darwin
import Foundation
import OhiaUninstallKit
import Security

// System facts the uninstall reads: Launch Services, code signatures,
// volumes, Ohia's calendar registration and the Mac's user folders.

nonisolated enum SystemLookup {
    /// Every Ohia.app Launch Services knows about.
    static func registeredOhiaCopies() async -> [URL] {
        await MainActor.run {
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: OhiaUninstallCatalog.appBundleID)
        }
    }

    /// Ohia is ours when its signature validates against our team. Resources
    /// are not hashed: identity rests on the executable's signature, and
    /// hashing every file of a large bundle would hold up the run.
    static func isOhiaFromTeam(_ url: URL) -> Bool {
        let requirementText = "anchor apple generic and identifier \"\(OhiaUninstallCatalog.appBundleID)\""
            + " and certificate leaf[subject.OU] = \"\(OhiaUninstallCatalog.teamID)\""
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources))
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The app's CFBundleVersion as an integer, read straight from its
    /// Info.plist (Bundle caches by path, and a copy may have been replaced).
    /// Nil when the plist can't be read or the version isn't an integer.
    static func bundleVersion(of app: URL) -> Int? {
        (infoPlist(of: app)?["CFBundleVersion"] as? String).flatMap { Int($0) }
    }

    /// The app's CFBundleIdentifier, read straight from its Info.plist.
    static func bundleIdentifier(of app: URL) -> String? {
        infoPlist(of: app)?["CFBundleIdentifier"] as? String
    }

    private static func infoPlist(of app: URL) -> [String: Any]? {
        let url = app.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func isWritableVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == false
    }

    /// Whether Ohia registered its deadline calendar, read from the sandboxed
    /// app's preferences at the start of the run, before step 5 deletes its
    /// container.
    static func calendarWasRegistered(home: URL) -> Bool {
        let id = OhiaUninstallCatalog.appBundleID
        let plist = home.appending(path: "Library/Containers/\(id)/Data/Library/Preferences/\(id).plist",
                                   directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return values[OhiaUninstallCatalog.calendarIdentifierDefaultsKey] is String
    }

    /// Opens the folder at `url` as the run will; the mapping from error
    /// numbers is `UninstallerAccessGate.probe`.
    static func probeAccess(_ url: URL) -> UninstallerAccessGate.Probe {
        UninstallerAccessGate.probe(
            lstatError: {
                var info = stat()
                return lstat(url.path, &info) == 0 ? 0 : errno
            },
            opendirError: {
                guard let directory = opendir(url.path) else { return errno }
                closedir(directory)
                return 0
            })
    }

    /// True when something, even a dangling symbolic link, is at `url`.
    static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Whether other people have home folders on this Mac.
    static func hasOtherUserHomes(excluding home: URL) -> Bool {
        let users = URL(fileURLWithPath: "/Users", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: users, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return false }
        let ownPath = home.standardizedFileURL.path
        return entries.contains { entry in
            guard !["Shared", "Guest"].contains(entry.lastPathComponent),
                  entry.standardizedFileURL.path != ownPath
            else { return false }
            return (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
