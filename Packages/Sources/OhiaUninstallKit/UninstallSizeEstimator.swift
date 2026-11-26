import Foundation

/// Measures the disk space a path occupies, for the uninstaller's
/// confirmation window. Symbolic links count as links and are never followed.
public enum UninstallSizeEstimator {
    public static func allocatedBytes(of url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let rootKind = entryKind(of: url) else { return 0 }
        guard rootKind == .directory else {
            return allocatedBytesOfEntry(at: url, kind: rootKind)
        }

        var total = allocatedBytesOfEntry(at: url, kind: rootKind)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
        // The enumerator does not descend into symlinked directories. Packages
        // are descended into because skipsPackageDescendants is left off.
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return total
        }
        for case let child as URL in enumerator {
            guard let kind = entryKind(of: child) else { continue }
            total += allocatedBytesOfEntry(at: child, kind: kind)
        }
        return total
    }

    /// What the confirmation window shows for Ohia's group container.
    public enum GroupContainerSize: Equatable, Sendable {
        /// Nothing is there.
        case absent
        /// Something is there that can't be listed (macOS refuses the folder
        /// without Full Disk Access) or examined.
        case notMeasured
        case measured(Int64)
    }

    /// Only a missing entry counts as absent. A link is measured as the link
    /// and never followed; a folder is measured when it can be opened.
    public static func groupContainerSize(of url: URL) -> GroupContainerSize {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .absent : .notMeasured
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard let directory = opendir(url.path) else { return .notMeasured }
            closedir(directory)
        }
        return .measured(allocatedBytes(of: url))
    }

    private enum EntryKind { case directory, symlink, other }

    private static func entryKind(of url: URL) -> EntryKind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory
        default: return .other
        }
    }

    private static func allocatedBytesOfEntry(at url: URL, kind: EntryKind) -> Int64 {
        if kind == .symlink {
            // Resource values may describe the link target; lstat describes the link.
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return 0 }
            return Int64(info.st_blocks) * 512
        }
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        if let size = values?.totalFileAllocatedSize {
            return Int64(size)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }
}
