import Foundation
import SQLite3
import simd

// SQLite requires the destructor argument of `sqlite3_bind_text` to be either
// SQLITE_STATIC or SQLITE_TRANSIENT; the latter tells SQLite to make its own
// copy of the bytes. Neither macro is bridged to Swift, so we reconstruct
// SQLITE_TRANSIENT (== -1 cast to a function pointer) ourselves. `VectorStore`
// has its own file-private copy of the same constant.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Per-frame settled positions for Constellation Mode. Shares the SQLite
/// handle with its host `VectorStore` (see `VectorNeighborsStore` for the
/// same pattern).
public final class VectorFrameLayoutStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock: SQLiteConnectionLock

    public convenience init(sharedDB: OpaquePointer) {
        self.init(sharedDB: sharedDB, lock: SQLiteConnectionLock())
    }

    public init(sharedDB: OpaquePointer, lock: SQLiteConnectionLock) {
        self.db = sharedDB
        self.lock = lock
    }

    public func upsertBatch(
        frame: FrameKey,
        positions: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)]
    ) throws {
        try lock.withLock {
        guard !positions.isEmpty else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }

        let sql = """
        INSERT INTO vector_frame_layout (vector_id, frame_key, layout_x, layout_y, layout_z, last_move_magnitude)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(vector_id, frame_key) DO UPDATE SET
            layout_x = excluded.layout_x,
            layout_y = excluded.layout_y,
            layout_z = excluded.layout_z,
            last_move_magnitude = excluded.last_move_magnitude;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for p in positions {
            sqlite3_bind_int64(stmt, 1, p.vectorId)
            sqlite3_bind_text(stmt, 2, frame.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, Double(p.xyz.x))
            sqlite3_bind_double(stmt, 4, Double(p.xyz.y))
            sqlite3_bind_double(stmt, 5, Double(p.xyz.z))
            sqlite3_bind_double(stmt, 6, Double(p.moveMagnitude))
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

    public func positionsForFrame(
        _ frame: FrameKey,
        vectorIds: [Int64]
    ) throws -> [Int64: SIMD3<Float>] {
        try lock.withLock {
        guard !vectorIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: vectorIds.count).joined(separator: ",")
        let sql = "SELECT vector_id, layout_x, layout_y, layout_z FROM vector_frame_layout WHERE frame_key = ? AND vector_id IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
        for (i, id) in vectorIds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(2 + i), id)
        }
        var out: [Int64: SIMD3<Float>] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            out[id] = SIMD3<Float>(
                Float(sqlite3_column_double(stmt, 1)),
                Float(sqlite3_column_double(stmt, 2)),
                Float(sqlite3_column_double(stmt, 3))
            )
        }
        return out
        }
    }

    /// Count of rows persisted for `frame`. Used by the orchestrator to decide
    /// between "seed from default and run a burst" (count == 0) and "continuous
    /// refine step" (count > 0).
    public func rowCount(frame: FrameKey) throws -> Int {
        try lock.withLock {
        let sql = "SELECT COUNT(*) FROM vector_frame_layout WHERE frame_key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Drop every persisted frame position whose vector belongs to `messageId`.
    public func deletePositions(forMessageId messageId: String) throws {
        try lock.withLock {
        let sql = """
        DELETE FROM vector_frame_layout
        WHERE vector_id IN (SELECT vector_id FROM vectors WHERE message_id = ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        }
    }
}
