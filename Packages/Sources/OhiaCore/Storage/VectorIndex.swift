import Foundation
import os
import USearch

// MARK: - Errors

public enum VectorIndexError: Error, Sendable {
    /// USearch returned a non-success status code on add/remove/search.
    case operationFailed(String)
    /// Caller passed a vector whose dimension does not match the index.
    case dimensionMismatch(expected: Int, got: Int)
}

// MARK: - Protocol

/// Per-collection ANN index for vector search. The index stores
/// `(Int64 key, [Float] vector)` pairs and supports cosine top-K queries.
///
/// Backed by USearch (HNSW) in production. Tests can substitute an in-memory
/// implementation. The implementation is responsible for thread safety.
public protocol VectorIndex: Sendable {
    /// Insert or replace the vector under `key` in the given collection.
    ///
    /// Calling `add` with an existing `key` overwrites the prior vector,
    /// mirroring re-embedding and index-reconciliation idempotency.
    func add(key: Int64, vector: [Float], collection: VectorCollection, embeddingVersion: String) throws

    /// Remove a vector by key. No-op if not present.
    func remove(key: Int64, collection: VectorCollection, embeddingVersion: String) throws

    /// Top-K nearest neighbors in the given collection. Returns `(key, distance)`
    /// pairs sorted by ascending cosine distance, where smaller is more similar.
    /// Returns an empty array when the collection has no vectors.
    func search(query: [Float], collection: VectorCollection, embeddingVersion: String, k: Int) throws -> [(key: Int64, distance: Float)]

    /// Number of vectors currently in the collection's index.
    func count(collection: VectorCollection, embeddingVersion: String) -> Int

    /// Set of all keys present in a collection. Used by the reconciler.
    /// May be expensive on large indices; not part of the hot path.
    func allKeys(collection: VectorCollection, embeddingVersion: String) -> Set<Int64>

    /// Persist all in-memory state for every collection to disk.
    func save() throws

    /// Drop all data across every collection. Mirrors `VectorStore.removeAllData`.
    func removeAllData() throws

    /// Drop all data for one embedding version after a completed migration.
    func removeAllData(embeddingVersion: String) throws
}

public extension VectorIndex {
    func add(key: Int64, vector: [Float], collection: VectorCollection) throws {
        try add(key: key, vector: vector, collection: collection, embeddingVersion: "current")
    }

    func remove(key: Int64, collection: VectorCollection) throws {
        try remove(key: key, collection: collection, embeddingVersion: "current")
    }

    func search(query: [Float], collection: VectorCollection, k: Int) throws -> [(key: Int64, distance: Float)] {
        try search(query: query, collection: collection, embeddingVersion: "current", k: k)
    }

    func count(collection: VectorCollection) -> Int {
        count(collection: collection, embeddingVersion: "current")
    }

    func allKeys(collection: VectorCollection) -> Set<Int64> {
        allKeys(collection: collection, embeddingVersion: "current")
    }
}

// MARK: - USearchVectorIndex

/// Production `VectorIndex` backed by one `USearchIndex` per
/// `(embeddingVersion, VectorCollection)`. Each tuple lives in its own
/// `index_<version>_<collection>.usearch` file under `directory`. Operations
/// are serialized by an internal lock so callers can share one index safely
/// across background jobs and UI read paths.
public final class USearchVectorIndex: VectorIndex, @unchecked Sendable {

    private static let logger = Logger(subsystem: "org.jgkarlin.Ohia", category: "VectorIndex")

    private static let collections: [VectorCollection] = [.context, .style, .attachment, .entity]

    /// HNSW connectivity (M parameter). Higher values trade memory for recall.
    private static let connectivity: UInt32 = 16

    private struct IndexKey: Hashable {
        let embeddingVersion: String
        let collection: VectorCollection
    }

    private let directory: URL
    private let lock = NSLock()
    private var dimensionsByVersion: [String: UInt32]
    private var indices: [IndexKey: USearchIndex] = [:]
    private var keySets: [IndexKey: Set<Int64>] = [:]
    private var reservedCapacities: [IndexKey: UInt32] = [:]

    public convenience init(directory: URL, dimensions: Int) throws {
        try self.init(directory: directory, dimensionsByVersion: ["current": dimensions])
    }

    public init(directory: URL, dimensionsByVersion: [String: Int]) throws {
        for (_, dimensions) in dimensionsByVersion {
            guard dimensions > 0 else {
                throw VectorIndexError.dimensionMismatch(expected: 1, got: dimensions)
            }
        }

        self.directory = directory
        self.dimensionsByVersion = dimensionsByVersion.mapValues { UInt32($0) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.removeStaleTemporaryFiles(in: directory)

        for version in dimensionsByVersion.keys {
            for collection in Self.collections {
                let key = IndexKey(embeddingVersion: version, collection: collection)
                indices[key] = try Self.makeIndex(dimensions: self.dimensions(for: version))
                keySets[key] = try loadPersistedStateDiscardingCorruption(key)
                try reserve(key: key, capacity: UInt32(max(1_024, keySets[key, default: []].count)))
            }
        }
    }

    /// Sweep leftover `.tmp-` files from a process that died between writing
    /// a temp index file and renaming it into place (see
    /// `saveIndexAtomically`).
    private static func removeStaleTemporaryFiles(in directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items where item.lastPathComponent.contains(".tmp-") {
            try? fm.removeItem(at: item)
        }
    }

    private static func makeIndex(dimensions: UInt32) throws -> USearchIndex {
        try USearchIndex.make(
            metric: .cos,
            dimensions: dimensions,
            connectivity: connectivity,
            quantization: .f32
        )
    }

    private func dimensions(for version: String) throws -> UInt32 {
        guard let dimensions = dimensionsByVersion[version] else {
            throw VectorIndexError.operationFailed("unknown embedding version: \(version)")
        }
        return dimensions
    }

    private func registerVersionIfNeededLocked(
        _ version: String,
        dimensions vectorDimensions: Int
    ) throws -> UInt32 {
        if let dimensions = dimensionsByVersion[version] {
            return dimensions
        }

        guard vectorDimensions > 0 else {
            throw VectorIndexError.dimensionMismatch(expected: 1, got: vectorDimensions)
        }

        let dimensions = UInt32(vectorDimensions)
        dimensionsByVersion[version] = dimensions
        for collection in Self.collections {
            let key = IndexKey(embeddingVersion: version, collection: collection)
            indices[key] = try Self.makeIndex(dimensions: dimensions)
            keySets[key] = try loadPersistedStateDiscardingCorruption(key)
            try reserve(key: key, capacity: UInt32(max(1_024, keySets[key, default: []].count)))
        }
        return dimensions
    }

    /// Load the persisted index + keys pair for `key`, treating the two files
    /// as one unit. The on-disk index is a derived cache of `VectorStore`, so
    /// malformed or inconsistent state is never fatal: both files are deleted,
    /// the collection starts empty, and the reconciler rebuilds it from the
    /// vector store. Before this policy, a file truncated by a process killed
    /// mid-save threw `loadFailed` out of `init`, which crash-looped the
    /// retrieval worker at every start until the file was deleted by hand.
    ///
    /// Requires `indices[key]` to exist. Only index re-creation errors
    /// propagate (allocation failure — genuinely unrecoverable); corruption
    /// is always swallowed after cleanup.
    private func loadPersistedStateDiscardingCorruption(_ key: IndexKey) throws -> Set<Int64> {
        let indexURL = indexFileURL(for: key)
        let keysURL = keysFileURL(for: key)
        let fileManager = FileManager.default

        let indexExists = fileManager.fileExists(atPath: indexURL.path)
        let keysExists = fileManager.fileExists(atPath: keysURL.path)
        guard indexExists || keysExists else { return [] }

        func discard() throws -> Set<Int64> {
            Self.logger.error(
                "Discarding unusable vector index cache version=\(key.embeddingVersion, privacy: .public) collection=\(key.collection.rawValue, privacy: .public); collection will rebuild from the vector store"
            )
            try? fileManager.removeItem(at: indexURL)
            try? fileManager.removeItem(at: keysURL)
            // A failed USearch load can leave the instance in a partial
            // state — replace it with a fresh empty index.
            indices[key] = try Self.makeIndex(dimensions: dimensions(for: key.embeddingVersion))
            return []
        }

        // The pair is written together by save(); one file without the other
        // means an interrupted or tampered save. Keeping the survivor would
        // desynchronize count()/allKeys() from the index contents and
        // suppress the reconciler's rebuild, so discard both.
        guard indexExists, keysExists else {
            return try discard()
        }

        do {
            try index(forLoadedKey: key).load(path: indexURL.path)
        } catch {
            return try discard()
        }

        do {
            let data = try Data(contentsOf: keysURL)
            return Set(try JSONDecoder().decode([Int64].self, from: data))
        } catch {
            return try discard()
        }
    }

    private func saveKeys(_ key: IndexKey) throws {
        let keys = Array(keySets[key, default: []]).sorted()
        let data = try JSONEncoder().encode(keys)
        try data.write(to: keysFileURL(for: key), options: .atomic)
    }

    private func indexFileURL(for key: IndexKey) -> URL {
        directory.appendingPathComponent("index_\(safeVersion(key.embeddingVersion))_\(key.collection.rawValue).usearch")
    }

    private func keysFileURL(for key: IndexKey) -> URL {
        directory.appendingPathComponent("keys_\(safeVersion(key.embeddingVersion))_\(key.collection.rawValue).json")
    }

    private func safeVersion(_ version: String) -> String {
        version
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func index(forLoadedKey key: IndexKey) -> USearchIndex {
        indices[key]!
    }

    private func index(for key: IndexKey) throws -> USearchIndex {
        if let index = indices[key] {
            return index
        }

        indices[key] = try Self.makeIndex(dimensions: dimensions(for: key.embeddingVersion))
        keySets[key] = try loadPersistedStateDiscardingCorruption(key)
        try reserve(key: key, capacity: UInt32(max(1_024, keySets[key, default: []].count)))
        // Re-read: corruption recovery may have replaced the instance.
        return indices[key]!
    }

    private func reserve(key: IndexKey, capacity: UInt32) throws {
        try index(forLoadedKey: key).reserve(capacity)
        reservedCapacities[key] = capacity
    }

    private func ensureCapacityForInsert(key: IndexKey, newKey: Int64) throws {
        let keySet = keySets[key, default: []]
        let desired = keySet.contains(newKey) ? keySet.count : keySet.count + 1
        let reserved = reservedCapacities[key, default: 0]
        guard desired > reserved else { return }

        var next = max(reserved, 1)
        while desired > next {
            next *= 2
        }
        try reserve(key: key, capacity: next)
    }

    private func usearchKey(_ key: Int64) throws -> USearchKey {
        guard key >= 0 else {
            throw VectorIndexError.operationFailed("USearch keys must be non-negative: \(key)")
        }
        return USearchKey(key)
    }

    public func add(key: Int64, vector: [Float], collection: VectorCollection) throws {
        try add(key: key, vector: vector, collection: collection, embeddingVersion: "current")
    }

    public func remove(key: Int64, collection: VectorCollection) throws {
        try remove(key: key, collection: collection, embeddingVersion: "current")
    }

    public func search(query: [Float], collection: VectorCollection, k: Int) throws -> [(key: Int64, distance: Float)] {
        try search(query: query, collection: collection, embeddingVersion: "current", k: k)
    }

    public func count(collection: VectorCollection) -> Int {
        count(collection: collection, embeddingVersion: "current")
    }

    public func allKeys(collection: VectorCollection) -> Set<Int64> {
        allKeys(collection: collection, embeddingVersion: "current")
    }

    // MARK: - VectorIndex

    public func add(key: Int64, vector: [Float], collection: VectorCollection, embeddingVersion: String) throws {
        let usearchKey = try usearchKey(key)
        let indexKey = IndexKey(embeddingVersion: embeddingVersion, collection: collection)
        lock.lock()
        defer { lock.unlock() }

        let dimensions = try registerVersionIfNeededLocked(
            embeddingVersion,
            dimensions: vector.count
        )
        guard vector.count == dimensions else {
            throw VectorIndexError.dimensionMismatch(expected: Int(dimensions), got: vector.count)
        }

        let idx = try index(for: indexKey)
        do {
            try ensureCapacityForInsert(key: indexKey, newKey: key)
            if try idx.contains(key: usearchKey) {
                _ = try idx.remove(key: usearchKey)
            }
            try idx.add(key: usearchKey, vector: vector)
            keySets[indexKey, default: []].insert(key)
        } catch {
            throw VectorIndexError.operationFailed("add version=\(embeddingVersion) collection=\(collection.rawValue) key=\(key): \(error)")
        }
    }

    public func remove(key: Int64, collection: VectorCollection, embeddingVersion: String) throws {
        let usearchKey = try usearchKey(key)
        let indexKey = IndexKey(embeddingVersion: embeddingVersion, collection: collection)
        lock.lock()
        defer { lock.unlock() }

        let idx = try index(for: indexKey)
        do {
            if try idx.contains(key: usearchKey) {
                _ = try idx.remove(key: usearchKey)
            }
            keySets[indexKey, default: []].remove(key)
        } catch {
            throw VectorIndexError.operationFailed("remove version=\(embeddingVersion) collection=\(collection.rawValue) key=\(key): \(error)")
        }
    }

    public func search(query: [Float], collection: VectorCollection, embeddingVersion: String, k: Int) throws -> [(key: Int64, distance: Float)] {
        let dimensions = try dimensions(for: embeddingVersion)
        guard query.count == dimensions else {
            throw VectorIndexError.dimensionMismatch(expected: Int(dimensions), got: query.count)
        }
        guard k > 0 else { return [] }

        let indexKey = IndexKey(embeddingVersion: embeddingVersion, collection: collection)
        lock.lock()
        defer { lock.unlock() }

        do {
            let (keys, distances) = try index(for: indexKey).search(vector: query, count: k)
            return zip(keys, distances).map { key, distance in
                (key: Int64(key), distance: Float(distance))
            }
        } catch {
            throw VectorIndexError.operationFailed("search version=\(embeddingVersion) collection=\(collection.rawValue): \(error)")
        }
    }

    public func count(collection: VectorCollection, embeddingVersion: String) -> Int {
        let indexKey = IndexKey(embeddingVersion: embeddingVersion, collection: collection)
        lock.lock()
        defer { lock.unlock() }
        return keySets[indexKey, default: []].count
    }

    public func allKeys(collection: VectorCollection, embeddingVersion: String) -> Set<Int64> {
        let indexKey = IndexKey(embeddingVersion: embeddingVersion, collection: collection)
        lock.lock()
        defer { lock.unlock() }
        return keySets[indexKey, default: []]
    }

    public func save() throws {
        lock.lock()
        defer { lock.unlock() }

        for (key, idx) in indices {
            do {
                try saveIndexAtomically(idx, to: indexFileURL(for: key))
                try saveKeys(key)
            } catch {
                throw VectorIndexError.operationFailed("save version=\(key.embeddingVersion) collection=\(key.collection.rawValue): \(error)")
            }
        }
    }

    /// USearch writes directly to the path it is given, so a process killed
    /// mid-save leaves a truncated file at the final location — which is
    /// exactly the corruption `loadPersistedStateDiscardingCorruption` has to
    /// clean up. Write to a sibling temp file and rename(2) it into place:
    /// the index file on disk is always either the previous complete save or
    /// the new complete save, never a partial write.
    private func saveIndexAtomically(_ idx: USearchIndex, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try idx.save(path: tempURL.path)
        guard rename(tempURL.path, url.path) == 0 else {
            throw VectorIndexError.operationFailed(
                "atomic rename to \(url.lastPathComponent) failed: errno=\(errno)"
            )
        }
    }

    public func removeAllData() throws {
        lock.lock()
        defer { lock.unlock() }

        for version in Array(dimensionsByVersion.keys) {
            try removeAllDataLocked(embeddingVersion: version)
        }
    }

    public func removeAllData(embeddingVersion: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try removeAllDataLocked(embeddingVersion: embeddingVersion)
    }

    private func removeAllDataLocked(embeddingVersion: String) throws {
        let dimensions = try dimensions(for: embeddingVersion)
        for collection in Self.collections {
            let key = IndexKey(embeddingVersion: embeddingVersion, collection: collection)
            indices[key] = try Self.makeIndex(dimensions: dimensions)
            keySets[key] = []
            try reserve(key: key, capacity: 1_024)
            try? FileManager.default.removeItem(at: indexFileURL(for: key))
            try? FileManager.default.removeItem(at: keysFileURL(for: key))
        }
    }
}
