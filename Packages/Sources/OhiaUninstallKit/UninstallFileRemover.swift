import Foundation

/// The file operations the remover needs, so tests can stand in for the
/// folders macOS protects.
public protocol UninstallFileSystem: Sendable {
    /// Whether the entry at `url` is a symbolic link, examined as the link
    /// itself (`lstat`). Throws when nothing is there or it can't be examined.
    func entryIsSymbolicLink(at url: URL) throws -> Bool
    /// The names in the folder at `url`, hidden ones included.
    func contentsOfDirectory(at url: URL) throws -> [String]
    /// Removes `url`, a symbolic link as the link, a folder with everything
    /// in it, never following links inside it.
    func removeItem(at url: URL) throws
}

/// The local disk, through FileManager.
public struct LocalFileSystem: UninstallFileSystem {
    public init() {}

    public func entryIsSymbolicLink(at url: URL) throws -> Bool {
        // attributesOfItem uses lstat, so a dangling or folder symlink is
        // seen as the link itself rather than as absent or as its target.
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    public func contentsOfDirectory(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    public func removeItem(at url: URL) throws {
        // removeItem unlinks a symlink itself and never traverses links
        // found inside a directory tree.
        try FileManager.default.removeItem(at: url)
    }
}

/// Deletes exact paths for the uninstaller. A symbolic link at a path is
/// removed as a link and never followed, so its target is left untouched.
public struct UninstallFileRemover: Sendable {
    public enum RemovalOutcome: Equatable, Sendable {
        case removed(URL)
        case absent(URL)
        case needsAdministrator(URL)
        case failed(URL, String)
        /// Needed an administrator, but its parent folder is not at its
        /// canonical path (moved, or reached through a link), so it was never
        /// sent to root (see AdminRemovalScript). The remover itself never
        /// returns this; the uninstall run assigns it.
        case folderNotWhereExpected(URL)
        /// In ~/Library/Containers or ~/Library/Group Containers, and macOS
        /// refused access to it. macOS refuses root there too, so it is never
        /// sent to an administrator.
        case deniedByMacOS(URL)
        /// Ohia's group container, which macOS lets only Ohia open: Ohia did
        /// not report it removed, and the uninstaller cannot open it.
        case onlyOhiaCanRemove(URL)
        /// An entry in Ohia's group container that Ohia's cleanup reported it
        /// could not remove, with the error number when it had one.
        case leftByOhia(URL, errorNumber: Int32?)
        /// Ohia's group container, about which Ohia's cleanup gave no usable
        /// report (it did not run, did not report back, or reported an
        /// outcome this build does not know), and which the uninstaller
        /// cannot open.
        case ohiaDidNotReport(URL)
    }

    private let fileSystem: any UninstallFileSystem

    public init(fileSystem: any UninstallFileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func remove(_ paths: [URL]) -> [RemovalOutcome] {
        paths.map(remove)
    }

    /// Removes a container macOS made for Ohia: every entry at its root
    /// except the bookkeeping file macOS keeps there, then the container
    /// itself. macOS refuses to let anyone remove that file, so a container
    /// left holding only it counts as removed; what decides is the container
    /// as it is afterwards, looked at again. Any other refusal inside it is
    /// macOS withholding Ohia's data (`deniedByMacOS`). A link in a
    /// container's place is removed as the link and never entered.
    public func removeContainer(_ container: URL) -> RemovalOutcome {
        do {
            if try fileSystem.entryIsSymbolicLink(at: container) {
                return remove(container)
            }
        } catch {
            return Self.isMissing(error) ? .absent(container) : containerOutcome(for: error, container)
        }

        // Every entry but macOS's file. A refusal or error is remembered, and
        // the rest is still removed.
        var insideError: Error?
        do {
            for name in try fileSystem.contentsOfDirectory(at: container)
            where name != OhiaUninstallCatalog.containerMetadataFileName {
                if let error = removeIfPresent(container.appending(path: name)), insideError == nil {
                    insideError = error
                }
            }
        } catch {
            return containerOutcome(for: error, container)
        }
        if let insideError {
            return containerOutcome(for: insideError, container)
        }

        // Then the container itself, which macOS's file keeps in place.
        do {
            try fileSystem.removeItem(at: container)
        } catch where !Self.isMissing(error) && !Self.isPermissionDenied(error) {
            return containerOutcome(for: error, container)
        } catch {}
        return containerAsItIsNow(container)
    }

    /// Empties a group container the uninstaller can open (with Full Disk
    /// Access), exactly as Ohia's own cleanup does.
    public func emptyGroupContainer(_ url: URL) -> UninstallCleanupResult.GroupContainerOutcome {
        GroupContainerCleaner.empty(url, fileSystem: fileSystem)
    }

    /// Whether anything is at `url`, a link included, examined as itself
    /// (`lstat`). Only a missing entry counts as absent; one that can't be
    /// examined counts as present.
    public func entryExists(_ url: URL) -> Bool {
        do {
            _ = try fileSystem.entryIsSymbolicLink(at: url)
            return true
        } catch {
            return !Self.isMissing(error)
        }
    }

    /// Whether `url` can be listed: false where macOS withholds it.
    public func canList(_ url: URL) -> Bool {
        (try? fileSystem.contentsOfDirectory(at: url)) != nil
    }

    /// Whether the container at `url` holds anything but macOS's file. False
    /// when it can't be listed.
    public func holdsMoreThanContainerMetadata(_ url: URL) -> Bool {
        guard let names = try? fileSystem.contentsOfDirectory(at: url) else { return false }
        return names.contains { $0 != OhiaUninstallCatalog.containerMetadataFileName }
    }

    /// Removed when nothing is at `container` any more, or only macOS's file
    /// is in it; otherwise macOS kept the rest.
    private func containerAsItIsNow(_ container: URL) -> RemovalOutcome {
        do {
            _ = try fileSystem.entryIsSymbolicLink(at: container)
        } catch {
            return Self.isMissing(error) ? .removed(container) : containerOutcome(for: error, container)
        }
        guard let left = try? fileSystem.contentsOfDirectory(at: container) else {
            return .deniedByMacOS(container)
        }
        return left.allSatisfy({ $0 == OhiaUninstallCatalog.containerMetadataFileName })
            ? .removed(container)
            : .deniedByMacOS(container)
    }

    private func remove(_ url: URL) -> RemovalOutcome {
        do {
            _ = try fileSystem.entryIsSymbolicLink(at: url)
        } catch {
            return Self.isMissing(error) ? .absent(url) : classify(error, url)
        }
        do {
            try fileSystem.removeItem(at: url)
            return .removed(url)
        } catch {
            return Self.isMissing(error) ? .absent(url) : classify(error, url)
        }
    }

    /// Removes `url` if something is there; the error, unless it was only
    /// missing.
    private func removeIfPresent(_ url: URL) -> Error? {
        do {
            try fileSystem.removeItem(at: url)
            return nil
        } catch {
            return Self.isMissing(error) ? nil : error
        }
    }

    private func containerOutcome(for error: Error, _ container: URL) -> RemovalOutcome {
        Self.isPermissionDenied(error)
            ? .deniedByMacOS(container)
            : .failed(container, (error as NSError).localizedDescription)
    }

    private func classify(_ error: Error, _ url: URL) -> RemovalOutcome {
        if Self.isPermissionDenied(error) {
            return .needsAdministrator(url)
        }
        return .failed(url, error.localizedDescription)
    }

    static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.fileNoSuchFile.rawValue
                || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
        }
        return false
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteNoPermission.rawValue
            || nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }
}

public typealias RemovalOutcome = UninstallFileRemover.RemovalOutcome
