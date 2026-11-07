import Foundation

public struct OhiaModelCacheEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let sizeBytes: Int64
    public let isActive: Bool

    public init(id: String, url: URL, sizeBytes: Int64, isActive: Bool) {
        self.id = id
        self.url = url
        self.sizeBytes = sizeBytes
        self.isActive = isActive
    }
}

public struct OhiaModelCacheSnapshot: Equatable, Sendable {
    public let directory: URL
    public let entries: [OhiaModelCacheEntry]

    public init(directory: URL, entries: [OhiaModelCacheEntry]) {
        self.directory = directory
        self.entries = entries
    }

    public var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.sizeBytes }
    }

    public var activeBytes: Int64 {
        entries.filter(\.isActive).reduce(0) { $0 + $1.sizeBytes }
    }

    public var inactiveBytes: Int64 {
        entries.filter { !$0.isActive }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var inactiveEntries: [OhiaModelCacheEntry] {
        entries.filter { !$0.isActive }
    }
}

public struct OhiaModelCachePruneResult: Equatable, Sendable {
    public let removedEntries: [OhiaModelCacheEntry]
    public let reclaimedBytes: Int64
    public let snapshotAfter: OhiaModelCacheSnapshot

    public init(
        removedEntries: [OhiaModelCacheEntry],
        reclaimedBytes: Int64,
        snapshotAfter: OhiaModelCacheSnapshot
    ) {
        self.removedEntries = removedEntries
        self.reclaimedBytes = reclaimedBytes
        self.snapshotAfter = snapshotAfter
    }
}

public struct OhiaModelCacheJanitor: Sendable {
    public let modelsDirectory: URL
    public let activeDirectoryNames: Set<String>

    public init(modelsDirectory: URL, activeDirectoryNames: Set<String>) {
        self.modelsDirectory = modelsDirectory
        self.activeDirectoryNames = activeDirectoryNames
    }

    public func snapshot() -> OhiaModelCacheSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelsDirectory.path) else {
            return OhiaModelCacheSnapshot(directory: modelsDirectory, entries: [])
        }

        let urls = (try? fm.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let entries = urls.compactMap { url -> OhiaModelCacheEntry? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true || values?.isSymbolicLink == true else { return nil }
            return OhiaModelCacheEntry(
                id: url.lastPathComponent,
                url: url,
                sizeBytes: Self.directorySize(url),
                isActive: activeDirectoryNames.contains(url.lastPathComponent)
            )
        }
        .sorted {
            if $0.isActive != $1.isActive { return $0.isActive && !$1.isActive }
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.id < $1.id
        }

        return OhiaModelCacheSnapshot(directory: modelsDirectory, entries: entries)
    }

    public func pruneInactive() throws -> OhiaModelCachePruneResult {
        let before = snapshot()
        let inactiveEntries = before.inactiveEntries
        let fm = FileManager.default
        for entry in inactiveEntries {
            do {
                try fm.removeItem(at: entry.url)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                continue
            }
        }
        let after = snapshot()
        return OhiaModelCachePruneResult(
            removedEntries: inactiveEntries,
            reclaimedBytes: inactiveEntries.reduce(0) { $0 + $1.sizeBytes },
            snapshotAfter: after
        )
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
