import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persists the namespaced sparse "meaning" feature dictionary extracted from
/// each summary vector's text payload, keyed by vector id. Written at the
/// embedding seam when the summary vector is inserted, and lazily backfilled
/// by the cluster-detection worker for rows embedded before the feature seam
/// existed. Shares the SQLite handle + lock with its host `VectorStore` (see
/// `VectorNeighborsStore` for the same sibling-store pattern); rows cascade
/// away when the parent vector is deleted.
public final class VectorMeaningFeatureStore: @unchecked Sendable {

    /// JSON payload format for `features_json`. Format 2 adds exact `tag:`
    /// keys beside the soft `meaning:` token features so cluster membership
    /// can require a shared canonical semantic tag.
    public static let currentFormat = 2

    private static let fetchChunkSize = 600

    private let db: OpaquePointer
    private let lock: SQLiteConnectionLock

    public convenience init(sharedDB: OpaquePointer) {
        self.init(sharedDB: sharedDB, lock: SQLiteConnectionLock())
    }

    public init(sharedDB: OpaquePointer, lock: SQLiteConnectionLock) {
        self.db = sharedDB
        self.lock = lock
    }

    /// Insert-or-replace feature rows in one transaction. Values are encoded
    /// as sorted-key JSON so identical feature dictionaries produce identical
    /// bytes.
    public func upsertBatch(_ rows: [(vectorId: Int64, features: [String: Float])]) throws {
        guard rows.isEmpty == false else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded: [(vectorId: Int64, json: String)] = try rows.map { row in
            let sanitized = row.features.filter { $0.value.isFinite }
            let data = try encoder.encode(sanitized)
            guard let json = String(data: data, encoding: .utf8) else {
                throw VectorStoreError.stepFailed("meaning features JSON encoding produced non-UTF8 data")
            }
            return (row.vectorId, json)
        }
        try lock.withLock {
        try exec("BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }
        var stmt: OpaquePointer?
        try prepare("""
        INSERT OR REPLACE INTO vector_meaning_features (vector_id, features_json, format)
        VALUES (?, ?, ?);
        """, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        for row in encoded {
            sqlite3_bind_int64(stmt, 1, row.vectorId)
            sqlite3_bind_text(stmt, 2, row.json, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(Self.currentFormat))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(stmt)
        }
        try exec("COMMIT;")
        committed = true
        }
    }

    /// Batched feature lookup. Ids are deduplicated and fetched in bounded
    /// `IN` chunks (mirroring `VectorNeighborsStore.neighborsOf(vectorIds:)`)
    /// so arbitrarily large corpora never exceed SQLite's bind-variable cap.
    /// Rows whose JSON fails to decode are skipped.
    public func features(for vectorIds: [Int64]) throws -> [Int64: [String: Float]] {
        guard vectorIds.isEmpty == false else { return [:] }
        let decoder = JSONDecoder()
        return try lock.withLock {
            var out: [Int64: [String: Float]] = [:]
            let uniqueIds = Array(Set(vectorIds)).sorted()
            for start in stride(from: 0, to: uniqueIds.count, by: Self.fetchChunkSize) {
                let chunk = Array(uniqueIds[start..<Swift.min(start + Self.fetchChunkSize, uniqueIds.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                SELECT vector_id, features_json
                FROM vector_meaning_features
                WHERE vector_id IN (\(placeholders)) AND format = ?;
                """
                var stmt: OpaquePointer?
                try prepare(sql, stmt: &stmt)
                defer { sqlite3_finalize(stmt) }
                for (index, id) in chunk.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(index + 1), id)
                }
                sqlite3_bind_int64(stmt, Int32(chunk.count + 1), Int64(Self.currentFormat))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let vectorId = sqlite3_column_int64(stmt, 0)
                    let json = String(cString: sqlite3_column_text(stmt, 1))
                    guard let data = json.data(using: .utf8),
                          let features = try? decoder.decode([String: Float].self, from: data) else {
                        continue
                    }
                    out[vectorId] = features
                }
            }
            return out
        }
    }

    /// The subset of `vectorIds` that has no persisted feature row yet,
    /// sorted ascending. Drives the worker's lazy backfill during a full
    /// refit.
    public func missingFeatureVectorIds(among vectorIds: [Int64]) throws -> [Int64] {
        guard vectorIds.isEmpty == false else { return [] }
        return try lock.withLock {
            var present: Set<Int64> = []
            let uniqueIds = Array(Set(vectorIds)).sorted()
            for start in stride(from: 0, to: uniqueIds.count, by: Self.fetchChunkSize) {
                let chunk = Array(uniqueIds[start..<Swift.min(start + Self.fetchChunkSize, uniqueIds.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                SELECT vector_id FROM vector_meaning_features
                WHERE vector_id IN (\(placeholders)) AND format = ?;
                """
                var stmt: OpaquePointer?
                try prepare(sql, stmt: &stmt)
                defer { sqlite3_finalize(stmt) }
                for (index, id) in chunk.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(index + 1), id)
                }
                sqlite3_bind_int64(stmt, Int32(chunk.count + 1), Int64(Self.currentFormat))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    present.insert(sqlite3_column_int64(stmt, 0))
                }
            }
            return uniqueIds.filter { present.contains($0) == false }
        }
    }

    private func prepare(_ sql: String, stmt: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}
