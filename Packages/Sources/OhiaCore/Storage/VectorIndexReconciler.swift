import Foundation

/// Repairs drift between `VectorStore` (SQLite source of truth) and
/// `VectorIndex` (ANN index). The reconciler is stateless and idempotent:
/// it walks SQLite once, re-adds rows missing from the ANN index, then removes
/// ANN keys that no longer have a SQLite row.
public enum VectorIndexReconciler {

    public struct Stats: Sendable, Equatable {
        public let scanned: Int
        public let added: Int
        public let removed: Int

        public init(scanned: Int, added: Int, removed: Int) {
            self.scanned = scanned
            self.added = added
            self.removed = removed
        }
    }

    private struct VersionedCollection: Hashable {
        let collection: VectorCollection
        let embeddingVersion: String
    }

    public static func reconcile(store: VectorStore, index: VectorIndex) throws -> Stats {
        var scanned = 0
        var added = 0
        var removed = 0

        var sqliteKeysByCollection: [VersionedCollection: Set<Int64>] = [:]
        var indexKeysByCollection: [VersionedCollection: Set<Int64>] = [:]

        for (collection, version) in try store.vectorIndexPartitions() {
            let key = VersionedCollection(collection: collection, embeddingVersion: version)
            sqliteKeysByCollection[key] = []
            indexKeysByCollection[key] = index.allKeys(
                collection: collection,
                embeddingVersion: version
            )
        }

        try store.enumerateForIndex { rowId, vector, collection, version in
            scanned += 1
            let key = VersionedCollection(collection: collection, embeddingVersion: version)
            sqliteKeysByCollection[key, default: []].insert(rowId)

            if indexKeysByCollection[key, default: []].contains(rowId) == false {
                try index.add(key: rowId, vector: vector, collection: collection, embeddingVersion: version)
                indexKeysByCollection[key, default: []].insert(rowId)
                added += 1
            }
        }

        for (key, indexKeys) in indexKeysByCollection {
            let sqliteKeys = sqliteKeysByCollection[key, default: []]
            let orphanKeys = indexKeys.subtracting(sqliteKeys)
            for rowId in orphanKeys {
                try index.remove(
                    key: rowId,
                    collection: key.collection,
                    embeddingVersion: key.embeddingVersion
                )
                removed += 1
            }
        }

        try index.save()
        return Stats(scanned: scanned, added: added, removed: removed)
    }
}
