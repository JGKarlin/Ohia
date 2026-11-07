import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persists top-K cosine-similarity neighbor lists keyed by source vector id.
/// Shares the SQLite handle with its host `VectorStore` to avoid a second
/// connection on the same file — SQLite's `SQLITE_OPEN_FULLMUTEX` serializes
/// access across callers, so the shared-handle pattern is safe.
public final class VectorNeighborsStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock: SQLiteConnectionLock

    public convenience init(sharedDB: OpaquePointer) {
        self.init(sharedDB: sharedDB, lock: SQLiteConnectionLock())
    }

    public init(sharedDB: OpaquePointer, lock: SQLiteConnectionLock) {
        self.db = sharedDB
        self.lock = lock
    }

    /// Insert (or replace, on `(source_vector_id, rank)` collision) a batch of
    /// neighbor edges inside a single transaction. `INSERT OR REPLACE` means
    /// re-running kNN for a source vector overwrites its prior top-K cleanly.
    public func insertBatch(_ neighbors: [VectorNeighbor]) throws {
        try lock.withLock {
        guard !neighbors.isEmpty else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        var committed = false
        defer {
            if !committed {
                // Best-effort rollback on any throw path; the real error has
                // already been surfaced up the stack.
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }
        let sql = """
        INSERT OR REPLACE INTO vector_neighbors (source_vector_id, target_vector_id, similarity, rank)
        VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for n in neighbors {
            let similarity = n.similarity.isFinite ? n.similarity : 0
            sqlite3_bind_int64(stmt, 1, n.sourceId)
            sqlite3_bind_int64(stmt, 2, n.targetId)
            sqlite3_bind_double(stmt, 3, Double(similarity))
            sqlite3_bind_int(stmt, 4, Int32(n.rank))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(stmt)
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        committed = true
        }
    }

    /// Returns the neighbor list of `vectorId` sorted by rank ascending, up to
    /// `limit`. Returns the empty array if the source has no persisted
    /// neighbors.
    public func neighborsOf(vectorId: Int64, limit: Int) throws -> [VectorNeighbor] {
        try lock.withLock {
        let sql = "SELECT target_vector_id, similarity, rank FROM vector_neighbors WHERE source_vector_id = ? ORDER BY rank ASC LIMIT \(limit);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, vectorId)
        var out: [VectorNeighbor] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(VectorNeighbor(
                sourceId: vectorId,
                targetId: sqlite3_column_int64(stmt, 0),
                similarity: Float(sqlite3_column_double(stmt, 1)),
                rank: Int(sqlite3_column_int(stmt, 2))
            ))
        }
        return out
        }
    }

    /// Batched neighbor lookup for render planning. Returns rows grouped by
    /// source vector id and sorted by rank within each source. This avoids the
    /// old Constellation pattern of issuing one SQLite statement per visible
    /// node while the user is interacting with the scene.
    public func neighborsOf(vectorIds: [Int64], limit: Int) throws -> [Int64: [VectorNeighbor]] {
        guard limit > 0, vectorIds.isEmpty == false else { return [:] }
        return try lock.withLock {
            var grouped: [Int64: [VectorNeighbor]] = [:]
            let uniqueIds = Array(Set(vectorIds)).sorted()
            let chunkSize = 600
            for start in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
                let chunk = Array(uniqueIds[start..<Swift.min(start + chunkSize, uniqueIds.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                SELECT source_vector_id, target_vector_id, similarity, rank
                FROM vector_neighbors
                WHERE source_vector_id IN (\(placeholders))
                  AND rank < ?
                ORDER BY source_vector_id ASC, rank ASC;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }
                for (i, id) in chunk.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(i + 1), id)
                }
                sqlite3_bind_int(stmt, Int32(chunk.count + 1), Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let source = sqlite3_column_int64(stmt, 0)
                    grouped[source, default: []].append(VectorNeighbor(
                        sourceId: source,
                        targetId: sqlite3_column_int64(stmt, 1),
                        similarity: Float(sqlite3_column_double(stmt, 2)),
                        rank: Int(sqlite3_column_int(stmt, 3))
                    ))
                }
            }
            return grouped
        }
    }

    /// For every source message that has at least one outgoing neighbor edge
    /// above `similarityThreshold`, returns the count of distinct
    /// neighbor messages it is linked to. Self-edges (where source and target
    /// belong to the same message) are excluded — every chunk would otherwise
    /// neighbor every other chunk in its own message, drowning out real
    /// inter-message structure. Used by the constellation hover's "in orbit"
    /// readout to express how tightly bound a node is to its neighborhood.
    public func messageNeighborCounts(similarityThreshold: Float = 0.60) throws -> [String: Int] {
        try lock.withLock {
        let sql = """
        SELECT src.message_id, COUNT(DISTINCT tgt.message_id)
        FROM vector_neighbors n
        JOIN vectors src ON src.vector_id = n.source_vector_id
        JOIN vectors tgt ON tgt.vector_id = n.target_vector_id
        WHERE n.similarity >= ?
          AND src.message_id != tgt.message_id
        GROUP BY src.message_id;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Double(similarityThreshold))
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int64(stmt, 1))
            out[messageId] = count
        }
        return out
        }
    }

    /// Message-level semantic affinities for a stored neighbor graph. Returns
    /// the best cosine edge between `messageId` and each neighboring message,
    /// considering both outgoing and incoming edges so callers are not
    /// sensitive to which side of the pair was refreshed most recently.
    public func messageAffinities(
        forMessageId messageId: String,
        limit: Int,
        similarityThreshold: Float = 0.60
    ) throws -> [String: Float] {
        guard limit > 0 else { return [:] }
        return try lock.withLock {
            var out: [String: Float] = [:]
            try readMessageAffinities(
                anchorMessageId: messageId,
                peerColumn: "tgt.message_id",
                anchorPredicate: "src.message_id = ?",
                peerPredicate: "tgt.message_id != ?",
                similarityThreshold: similarityThreshold,
                limit: limit,
                into: &out
            )
            try readMessageAffinities(
                anchorMessageId: messageId,
                peerColumn: "src.message_id",
                anchorPredicate: "tgt.message_id = ?",
                peerPredicate: "src.message_id != ?",
                similarityThreshold: similarityThreshold,
                limit: limit,
                into: &out
            )
            return out
        }
    }

    private func readMessageAffinities(
        anchorMessageId: String,
        peerColumn: String,
        anchorPredicate: String,
        peerPredicate: String,
        similarityThreshold: Float,
        limit: Int,
        into out: inout [String: Float]
    ) throws {
        let sql = """
        SELECT \(peerColumn), MAX(n.similarity) AS score
        FROM vector_neighbors n
        JOIN vectors src ON src.vector_id = n.source_vector_id
        JOIN vectors tgt ON tgt.vector_id = n.target_vector_id
        WHERE \(anchorPredicate)
          AND \(peerPredicate)
          AND n.similarity >= ?
        GROUP BY \(peerColumn)
        ORDER BY score DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, anchorMessageId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, anchorMessageId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, Double(similarityThreshold))
        sqlite3_bind_int(stmt, 4, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let peer = String(cString: sqlite3_column_text(stmt, 0))
            let score = Float(sqlite3_column_double(stmt, 1))
            if let existing = out[peer] {
                out[peer] = max(existing, score)
            } else {
                out[peer] = score
            }
        }
    }

    /// Manually wipes edges incident on `vectorId` in either direction.
    /// `vector_neighbors` has `ON DELETE CASCADE` against `vectors(vector_id)`
    /// so deleting the parent row makes this redundant, but the method is
    /// useful for tests and for recomputation paths that want to clear before
    /// re-inserting.
    public func deleteNeighbors(for vectorId: Int64) throws {
        try lock.withLock {
        let sql = "DELETE FROM vector_neighbors WHERE source_vector_id = ? OR target_vector_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, vectorId)
        sqlite3_bind_int64(stmt, 2, vectorId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        }
    }

    /// Delete every neighbor edge incident on a vector belonging to `messageId`.
    public func deleteNeighbors(forMessageId messageId: String) throws {
        try lock.withLock {
        let sql = """
        DELETE FROM vector_neighbors
        WHERE source_vector_id IN (SELECT vector_id FROM vectors WHERE message_id = ?)
           OR target_vector_id IN (SELECT vector_id FROM vectors WHERE message_id = ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, messageId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        }
    }
}
