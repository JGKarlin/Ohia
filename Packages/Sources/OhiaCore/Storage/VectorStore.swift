import Accelerate
import Foundation
import SQLite3

// MARK: - SQLITE_TRANSIENT workaround

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteConnectionLock: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    public init() {}

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Error

public enum VectorStoreError: Error, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case dimensionMismatch
    case nearZeroVectorNorm(normSquared: Float)
}

extension VectorStoreError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .openFailed(let message):
            return "VectorStore open failed: \(message)"
        case .prepareFailed(let message):
            return "VectorStore prepare failed: \(message)"
        case .stepFailed(let message):
            return "VectorStore step failed: \(message)"
        case .dimensionMismatch:
            return "VectorStore dimension mismatch"
        case .nearZeroVectorNorm(let normSquared):
            return "VectorStore refused near-zero embedding vector (squared norm: \(normSquared))"
        }
    }
}

// MARK: - Types

public struct VectorRecord: Sendable {
    public let vectorId: Int64
    public let messageId: String
    public let collection: VectorCollection
    public let chunkIndex: Int
    public let embeddingVersion: String
    public let vector: [Float]
    public let textPayload: String
    public let metadataJSON: String
    public let createdAt: String
    public let layoutX: Float?
    public let layoutY: Float?
    public let layoutZ: Float?
    public let arrivalTime: TimeInterval?
    public let lastMoveMagnitude: Float?
    /// Unix epoch seconds of `Message.vectorTimeFilterDate`. Source of truth
    /// for the HUD time-filter buttons — unlike `arrivalTime`, this stays
    /// fixed to the message's own date across re-indexing or layout rebuilds.
    public let messageReceivedAt: TimeInterval?
    public let entityKind: EntityKind?
    public let entityKey: String?
    public let entityScore: Float?

    public init(
        vectorId: Int64,
        messageId: String,
        collection: VectorCollection,
        chunkIndex: Int,
        embeddingVersion: String,
        vector: [Float],
        textPayload: String,
        metadataJSON: String,
        createdAt: String,
        layoutX: Float? = nil,
        layoutY: Float? = nil,
        layoutZ: Float? = nil,
        arrivalTime: TimeInterval? = nil,
        lastMoveMagnitude: Float? = nil,
        messageReceivedAt: TimeInterval? = nil,
        entityKind: EntityKind? = nil,
        entityKey: String? = nil,
        entityScore: Float? = nil
    ) {
        self.vectorId = vectorId
        self.messageId = messageId
        self.collection = collection
        self.chunkIndex = chunkIndex
        self.embeddingVersion = embeddingVersion
        self.vector = vector
        self.textPayload = textPayload
        self.metadataJSON = metadataJSON
        self.createdAt = createdAt
        self.layoutX = layoutX
        self.layoutY = layoutY
        self.layoutZ = layoutZ
        self.arrivalTime = arrivalTime
        self.lastMoveMagnitude = lastMoveMagnitude
        self.messageReceivedAt = messageReceivedAt
        self.entityKind = entityKind
        self.entityKey = entityKey
        self.entityScore = entityScore
    }
}

public struct SearchResult: Sendable {
    public let record: VectorRecord
    public let score: Float

    public var textPayload: String { record.textPayload }
    public var collection: VectorCollection { record.collection }
}

/// Per-message vector tally split by collection. Drives the constellation
/// hover's orbital-glyph "moons" — each moon is colored by collection so
/// the glyph is honest about the underlying breakdown.
public struct MessageVectorCountBreakdown: Sendable, Equatable {
    public var context: Int
    public var attachment: Int
    public var entity: Int

    public init(context: Int = 0, attachment: Int = 0, entity: Int = 0) {
        self.context = context
        self.attachment = attachment
        self.entity = entity
    }

    public var total: Int { context + attachment + entity }
}

public struct VectorInsertRequest: Sendable {
    public let messageId: String
    public let collection: VectorCollection
    public let chunkIndex: Int
    public let embeddingVersion: String
    public let vector: [Float]
    public let textPayload: String
    public let metadataJSON: String
    public let messageReceivedAt: TimeInterval?

    public init(
        messageId: String,
        collection: VectorCollection,
        chunkIndex: Int,
        embeddingVersion: String,
        vector: [Float],
        textPayload: String,
        metadataJSON: String,
        messageReceivedAt: TimeInterval? = nil
    ) {
        self.messageId = messageId
        self.collection = collection
        self.chunkIndex = chunkIndex
        self.embeddingVersion = embeddingVersion
        self.vector = vector
        self.textPayload = textPayload
        self.metadataJSON = metadataJSON
        self.messageReceivedAt = messageReceivedAt
    }
}

public struct VectorMessageDateRepair: Sendable {
    public let messageId: String
    public let timestamp: TimeInterval?

    public init(messageId: String, timestamp: TimeInterval?) {
        self.messageId = messageId
        self.timestamp = timestamp
    }
}

public enum ScopeOrder: Sendable, Equatable {
    case receivedDesc
    case receivedAsc
    case messageIdAsc
}

// MARK: - VectorStore

public final class VectorStore: @unchecked Sendable {
    private static let busyTimeoutMilliseconds: Int32 = 10_000

    /// ANN index for top-K cosine search. Optional only because some legacy
    /// initializers and unit tests construct `VectorStore` without it.
    /// Production code paths through `AppServices` supply one.
    private let index: VectorIndex?
    private let db: OpaquePointer
    private let dbLock = SQLiteConnectionLock()
    private var isClosed = false

    /// Raw SQLite handle shared with sibling stores (e.g. `VectorNeighborsStore`)
    /// that need to operate on the same database file without opening a second
    /// connection. Access is serialized by SQLite's `SQLITE_OPEN_FULLMUTEX`.
    public var rawHandle: OpaquePointer { db }
    public var rawLock: SQLiteConnectionLock { dbLock }

    // MARK: - Init / Deinit

    /// Open the SQLite file at `path` read-only and return distinct
    /// embedding versions already present in the vectors table. Fresh installs
    /// or pre-vector stores return an empty list.
    public static func peekEmbeddingVersions(at path: String) throws -> [String] {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let opened = handle else { return [] }
        defer { sqlite3_close(opened) }
        sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)

        // This probe intentionally runs before `VectorStore.init` performs
        // schema migrations. Older stores therefore cannot be assumed to have
        // the reversible `is_active` column yet.
        let sql = "SELECT DISTINCT embedding_version FROM vectors;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(opened, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var versions: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            versions.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return versions
    }

    public convenience init(path: String) throws {
        try self.init(path: path, index: nil)
    }

    public init(path: String, index: VectorIndex?) throws {
        self.index = index
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw VectorStoreError.openFailed(msg)
        }
        db = opened
        try configureConnection()
        try createSchema()
    }

    /// Deterministically closes the SQLite connection. Idempotent, so calling
    /// it and then letting `deinit` run is safe.
    ///
    /// Call this before deleting the database file. Relying on `deinit` alone
    /// binds the close to ARC's release timing, which can lag a caller's
    /// teardown (e.g. a test's `removeItem(at: tmpDir)` in a `defer`): the file
    /// is then unlinked while this handle is still open, which the macOS SQLite
    /// VFS reports as a non-fatal "vnode unlinked while in use" log and, on a
    /// live store, surfaces as `disk I/O error` (see `removeAllData()`).
    ///
    /// Invalidates `rawHandle`/`rawLock` for any sibling stores
    /// (`VectorNeighborsStore`, `VectorClusterStore`, `VectorFrameLayoutStore`):
    /// only close once nothing will touch the shared handle again.
    public func close() {
        dbLock.withLock {
            guard !isClosed else { return }
            isClosed = true
            sqlite3_close(db)
        }
    }

    deinit {
        if !isClosed { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func createSchema() throws {
        let ddl = """
        CREATE TABLE IF NOT EXISTS vectors (
            vector_id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id TEXT NOT NULL,
            collection TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            embedding_version TEXT NOT NULL,
            vector BLOB NOT NULL,
            text_payload TEXT NOT NULL,
            metadata_json TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS message_semantic_visibility (
            message_id TEXT PRIMARY KEY,
            is_active INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_vectors_collection ON vectors(collection);
        CREATE INDEX IF NOT EXISTS idx_vectors_message_id ON vectors(message_id);
        CREATE TABLE IF NOT EXISTS vector_neighbors (
            source_vector_id INTEGER NOT NULL,
            target_vector_id INTEGER NOT NULL,
            similarity REAL NOT NULL,
            rank INTEGER NOT NULL,
            PRIMARY KEY (source_vector_id, rank),
            FOREIGN KEY (source_vector_id) REFERENCES vectors(vector_id) ON DELETE CASCADE,
            FOREIGN KEY (target_vector_id) REFERENCES vectors(vector_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_vector_neighbors_source ON vector_neighbors(source_vector_id);
        CREATE INDEX IF NOT EXISTS idx_vector_neighbors_target ON vector_neighbors(target_vector_id);
        CREATE TABLE IF NOT EXISTS vector_frame_layout (
            vector_id INTEGER NOT NULL,
            frame_key TEXT NOT NULL,
            layout_x REAL NOT NULL,
            layout_y REAL NOT NULL,
            layout_z REAL NOT NULL,
            last_move_magnitude REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (vector_id, frame_key),
            FOREIGN KEY (vector_id) REFERENCES vectors(vector_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_vector_frame_layout_frame ON vector_frame_layout(frame_key);
        CREATE TABLE IF NOT EXISTS vector_clusters (
            cluster_id INTEGER PRIMARY KEY AUTOINCREMENT,
            frame_key TEXT NOT NULL,
            centroid_x REAL NOT NULL,
            centroid_y REAL NOT NULL,
            centroid_z REAL NOT NULL,
            member_count INTEGER NOT NULL,
            detected_at REAL NOT NULL,
            label TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_vector_clusters_frame ON vector_clusters(frame_key);
        CREATE TABLE IF NOT EXISTS vector_cluster_members (
            cluster_id INTEGER NOT NULL,
            vector_id INTEGER NOT NULL,
            weight REAL NOT NULL DEFAULT 1.0,
            PRIMARY KEY (cluster_id, vector_id),
            FOREIGN KEY (cluster_id) REFERENCES vector_clusters(cluster_id) ON DELETE CASCADE,
            FOREIGN KEY (vector_id) REFERENCES vectors(vector_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_vector_cluster_members_vector ON vector_cluster_members(vector_id);
        CREATE TABLE IF NOT EXISTS vector_meaning_features (
            vector_id INTEGER PRIMARY KEY REFERENCES vectors(vector_id) ON DELETE CASCADE,
            features_json TEXT NOT NULL,
            format INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS vector_cluster_runs (
            frame_key TEXT PRIMARY KEY,
            input_fingerprint TEXT NOT NULL,
            full_refit_at REAL NOT NULL,
            incremental_adds INTEGER NOT NULL DEFAULT 0
        );
        """
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, ddl, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw VectorStoreError.prepareFailed(msg)
        }
        // Idempotent column additions for layout state. Each guarded by
        // PRAGMA table_info so re-opening a DB with pre-existing columns is a
        // no-op.
        try addColumnIfMissing("vectors", column: "layout_x", type: "REAL")
        try addColumnIfMissing("vectors", column: "layout_y", type: "REAL")
        try addColumnIfMissing("vectors", column: "layout_z", type: "REAL")
        try addColumnIfMissing("vectors", column: "arrival_time", type: "REAL")
        try addColumnIfMissing("vectors", column: "last_move_magnitude", type: "REAL")
        // Unix-epoch seconds of the underlying message's
        // `vectorTimeFilterDate`. Populated at `insert` time. Distinct from
        // `arrival_time`, which is the vector's layout-placement timestamp
        // (set by the constellation indexer and re-stamped on layout
        // rebuild). The HUD time-filter buttons query this column so tapping
        // "Today" means "emails dated today," not "vectors placed today" —
        // the latter would collapse empty at midnight and would surface a
        // 2020 email under Today simply because backfill reached that
        // message in the last 24h.
        try addColumnIfMissing("vectors", column: "message_received_at", type: "REAL")
        try addColumnIfMissing("vectors", column: "entity_kind", type: "TEXT")
        try addColumnIfMissing("vectors", column: "entity_key", type: "TEXT")
        try addColumnIfMissing("vectors", column: "entity_score", type: "REAL")
        try addColumnIfMissing("vectors", column: "is_active", type: "INTEGER NOT NULL DEFAULT 1")
        try exec("""
        INSERT OR IGNORE INTO message_semantic_visibility (message_id, is_active)
        SELECT message_id, MIN(is_active)
        FROM vectors
        GROUP BY message_id;
        """)
        // Membership weight for cluster identity/attachment. Legacy rows read
        // back 1.0 (full membership), matching the DBSCAN semantics they were
        // written under.
        try addColumnIfMissing("vector_cluster_members", column: "weight", type: "REAL NOT NULL DEFAULT 1.0")
        try exec("CREATE INDEX IF NOT EXISTS idx_vectors_entity_kind_key ON vectors(entity_kind, entity_key);")
        try exec("CREATE INDEX IF NOT EXISTS idx_vectors_unplaced ON vectors(vector_id) WHERE layout_x IS NULL;")
        try exec("CREATE INDEX IF NOT EXISTS idx_vectors_unplaced_received_at ON vectors(message_received_at DESC, vector_id) WHERE layout_x IS NULL;")
        try exec("CREATE INDEX IF NOT EXISTS idx_vectors_placed ON vectors(vector_id) WHERE layout_x IS NOT NULL;")
        try exec("CREATE INDEX IF NOT EXISTS idx_vectors_received_at ON vectors(message_received_at);")
        try exec("CREATE INDEX IF NOT EXISTS idx_vectors_embedding_version_message ON vectors(embedding_version, message_id);")
    }

    private func configureConnection() throws {
        guard sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds) == SQLITE_OK else {
            throw VectorStoreError.openFailed(String(cString: sqlite3_errmsg(db)))
        }

        // The foreground app continuously reads vectors for Constellation while
        // the worker writes embeddings/layout rows. WAL keeps readers from
        // blocking the writer, and the busy timeout turns short write races
        // into waits instead of immediate "database is locked" retries.
        try exec("PRAGMA busy_timeout = \(Self.busyTimeoutMilliseconds);")
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA temp_store = MEMORY;")
        try exec("PRAGMA wal_autocheckpoint = 1000;")

        // Foreign-key enforcement is off by default in SQLite. The
        // vector_neighbors cascade-delete relies on it — a silent failure here
        // would mean deleted parent rows leave orphan neighbor edges.
        try exec("PRAGMA foreign_keys = ON;")
    }

    private func addColumnIfMissing(_ table: String, column: String, type: String) throws {
        var stmt: OpaquePointer?
        let pragma = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            if name == column { return } // already present
        }
        let alter = "ALTER TABLE \(table) ADD COLUMN \(column) \(type);"
        if sqlite3_exec(db, alter, nil, nil, nil) != SQLITE_OK {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Insert

    @discardableResult
    public func insert(
        messageId: String,
        collection: VectorCollection,
        chunkIndex: Int,
        embeddingVersion: String,
        vector: [Float],
        textPayload: String,
        metadataJSON: String,
        messageReceivedAt: TimeInterval? = nil
    ) throws -> Int64 {
        try dbLock.withLock {
        // `message_received_at` is the message-date column queried by the
        // Constellation HUD time filter. Callers in the embed pipeline
        // supply `Message.vectorTimeFilterDate`; nil is retained only for
        // non-message rows or older callers.
        let sanitizedVector = try validatedVector(vector)
        let sql = """
        INSERT INTO vectors
            (message_id, collection, chunk_index, embedding_version, vector, text_payload, metadata_json, message_received_at, is_active)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, COALESCE(
            (SELECT is_active FROM message_semantic_visibility WHERE message_id = ?),
            1
        ));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, collection.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(stmt, 3, Int64(chunkIndex))
        sqlite3_bind_text(stmt, 4, embeddingVersion, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        let blobData = vectorToData(sanitizedVector)
        blobData.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blobData.count), SQLITE_TRANSIENT_DESTRUCTOR)
        }

        sqlite3_bind_text(stmt, 6, textPayload, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 7, metadataJSON, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let messageReceivedAt {
            sqlite3_bind_double(stmt, 8, messageReceivedAt)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_text(stmt, 9, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        let rowId = sqlite3_last_insert_rowid(db)
        if try vectorRowIsActiveLocked(rowId) {
            try index?.add(key: rowId, vector: sanitizedVector, collection: collection, embeddingVersion: embeddingVersion)
        }
        return rowId
        }
    }

    @discardableResult
    public func insertBatch(_ requests: [VectorInsertRequest]) throws -> [Int64] {
        try dbLock.withLock {
            guard !requests.isEmpty else { return [] }
            let sanitized = try requests.map { request in
                (request: request, vector: try validatedVector(request.vector))
            }
            let sql = """
            INSERT INTO vectors
                (message_id, collection, chunk_index, embedding_version, vector, text_payload, metadata_json, message_received_at, is_active)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, COALESCE(
                (SELECT is_active FROM message_semantic_visibility WHERE message_id = ?),
                1
            ));
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            try exec("BEGIN IMMEDIATE;")
            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }

            var rows: [(
                id: Int64,
                vector: [Float],
                collection: VectorCollection,
                version: String,
                isActive: Bool
            )] = []
            rows.reserveCapacity(sanitized.count)
            for item in sanitized {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                sqlite3_bind_text(stmt, 1, item.request.messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 2, item.request.collection.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_int64(stmt, 3, Int64(item.request.chunkIndex))
                sqlite3_bind_text(stmt, 4, item.request.embeddingVersion, -1, SQLITE_TRANSIENT_DESTRUCTOR)

                let blobData = vectorToData(item.vector)
                blobData.withUnsafeBytes { ptr in
                    _ = sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blobData.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }

                sqlite3_bind_text(stmt, 6, item.request.textPayload, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 7, item.request.metadataJSON, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                if let messageReceivedAt = item.request.messageReceivedAt {
                    sqlite3_bind_double(stmt, 8, messageReceivedAt)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                sqlite3_bind_text(stmt, 9, item.request.messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                let rowId = sqlite3_last_insert_rowid(db)
                rows.append((
                    id: rowId,
                    vector: item.vector,
                    collection: item.request.collection,
                    version: item.request.embeddingVersion,
                    isActive: try vectorRowIsActiveLocked(rowId)
                ))
            }

            try exec("COMMIT;")
            committed = true

            for row in rows where row.isActive {
                try index?.add(
                    key: row.id,
                    vector: row.vector,
                    collection: row.collection,
                    embeddingVersion: row.version
                )
            }
            return rows.map { $0.id }
        }
    }

    @discardableResult
    public func insertEntity(
        entityId: String,
        kind: EntityKind,
        entityKey: String,
        entityScore: Float,
        embeddingVersion: String,
        vector: [Float],
        textPayload: String,
        metadataJSON: String
    ) throws -> Int64 {
        try dbLock.withLock {
        let sanitizedVector = try validatedVector(vector)
        let sql = """
        INSERT INTO vectors
            (message_id, collection, chunk_index, embedding_version, vector, text_payload, metadata_json, entity_kind, entity_key, entity_score)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, entityId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, VectorCollection.entity.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(stmt, 3, 0)
        sqlite3_bind_text(stmt, 4, embeddingVersion, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        let blobData = vectorToData(sanitizedVector)
        blobData.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blobData.count), SQLITE_TRANSIENT_DESTRUCTOR)
        }

        sqlite3_bind_text(stmt, 6, textPayload, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 7, metadataJSON, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 8, kind.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 9, entityKey, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_double(stmt, 10, Double(entityScore))

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        let rowId = sqlite3_last_insert_rowid(db)
        try index?.add(key: rowId, vector: sanitizedVector, collection: .entity, embeddingVersion: embeddingVersion)
        return rowId
        }
    }

    // MARK: - Query by message

    public func vectorsForMessage(messageId: String) throws -> [VectorRecord] {
        let sql = "SELECT vector_id, message_id, collection, chunk_index, embedding_version, vector, text_payload, metadata_json, created_at, layout_x, layout_y, layout_z, arrival_time, last_move_magnitude, message_received_at, entity_kind, entity_key, entity_score FROM vectors WHERE message_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        var results: [VectorRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(try rowToRecord(stmt))
        }
        return results
    }

    /// Fetches one collection for many messages without issuing one SQLite
    /// statement per message. Requests are deduplicated and chunked so a full
    /// historical corpus never exceeds SQLite's bound-variable limit.
    public func vectorsForMessages(
        messageIds: [String],
        collection: VectorCollection
    ) throws -> [String: [VectorRecord]] {
        let uniqueMessageIDs = Array(Set(messageIds)).sorted()
        guard !uniqueMessageIDs.isEmpty else { return [:] }

        return try dbLock.withLock {
            var recordsByMessageID: [String: [VectorRecord]] = [:]
            let batchSize = 400
            for start in stride(from: 0, to: uniqueMessageIDs.count, by: batchSize) {
                let end = min(start + batchSize, uniqueMessageIDs.count)
                let batch = uniqueMessageIDs[start..<end]
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let sql = """
                SELECT vector_id, message_id, collection, chunk_index, embedding_version,
                       vector, text_payload, metadata_json, created_at, layout_x, layout_y,
                       layout_z, arrival_time, last_move_magnitude, message_received_at,
                       entity_kind, entity_key, entity_score
                FROM vectors
                WHERE collection = ? AND message_id IN (\(placeholders))
                ORDER BY message_id, chunk_index, vector_id;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                      let stmt else {
                    throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_text(stmt, 1, collection.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                for (offset, messageID) in batch.enumerated() {
                    sqlite3_bind_text(
                        stmt,
                        Int32(offset + 2),
                        messageID,
                        -1,
                        SQLITE_TRANSIENT_DESTRUCTOR
                    )
                }

                while true {
                    let result = sqlite3_step(stmt)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else {
                        throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                    }
                    let record = try rowToRecord(stmt)
                    recordsByMessageID[record.messageId, default: []].append(record)
                }
            }
            return recordsByMessageID
        }
    }

    /// Change whether a message participates in active semantic work while
    /// retaining every vector row, layout coordinate, and text payload. The
    /// SQLite bit is authoritative; the resident ANN index is a derived cache
    /// updated best-effort and reconciled automatically if a cache write fails.
    public func setMessageActive(messageId: String, isActive: Bool) throws {
        try dbLock.withLock {
            let records = try vectorsForMessage(messageId: messageId)
            try withTransaction {
                let visibilitySQL = """
                INSERT INTO message_semantic_visibility (message_id, is_active)
                VALUES (?, ?)
                ON CONFLICT(message_id) DO UPDATE SET is_active = excluded.is_active;
                """
                var visibilityStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, visibilitySQL, -1, &visibilityStmt, nil) == SQLITE_OK,
                      let visibilityStmt else {
                    throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(visibilityStmt) }
                sqlite3_bind_text(visibilityStmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_int64(visibilityStmt, 2, isActive ? 1 : 0)
                guard sqlite3_step(visibilityStmt) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }

                let sql = "UPDATE vectors SET is_active = ? WHERE message_id = ?;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, isActive ? 1 : 0)
                sqlite3_bind_text(stmt, 2, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }

                if try tableHasColumn("is_active", in: "message_filter_metadata") {
                    let metadataSQL = """
                    INSERT INTO message_filter_metadata
                        (message_id, sender_email, has_attachment, is_active)
                    VALUES (?, '', 0, ?)
                    ON CONFLICT(message_id) DO UPDATE SET is_active = excluded.is_active;
                    """
                    var metadataStmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, metadataSQL, -1, &metadataStmt, nil) == SQLITE_OK,
                          let metadataStmt else {
                        throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                    }
                    defer { sqlite3_finalize(metadataStmt) }
                    sqlite3_bind_text(metadataStmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_int64(metadataStmt, 2, isActive ? 1 : 0)
                    guard sqlite3_step(metadataStmt) == SQLITE_DONE else {
                        throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                    }
                }
            }

            for record in records {
                if isActive {
                    try? index?.add(
                        key: record.vectorId,
                        vector: record.vector,
                        collection: record.collection,
                        embeddingVersion: record.embeddingVersion
                    )
                } else {
                    try? index?.remove(
                        key: record.vectorId,
                        collection: record.collection,
                        embeddingVersion: record.embeddingVersion
                    )
                }
            }
            try? index?.save()
        }
    }

    private func vectorRowIsActiveLocked(_ vectorId: Int64) throws -> Bool {
        let sql = "SELECT is_active FROM vectors WHERE vector_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, vectorId)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw VectorStoreError.stepFailed("Inserted vector row \(vectorId) was not readable")
        }
        return sqlite3_column_int64(stmt, 0) != 0
    }

    // MARK: - Delete

    public func deleteVectors(forMessageId messageId: String) throws {
        try dbLock.withLock {
        let pairs = try vectorIdsAndCollections(forMessageId: messageId)

        let sql = "DELETE FROM vectors WHERE message_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }

        for (rowId, collection, version) in pairs {
            try? index?.remove(key: rowId, collection: collection, embeddingVersion: version)
        }
        }
    }

    private func vectorIdsAndCollections(forMessageId messageId: String) throws -> [(Int64, VectorCollection, String)] {
        let sql = "SELECT vector_id, collection, embedding_version FROM vectors WHERE message_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        var pairs: [(Int64, VectorCollection, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let raw = String(cString: sqlite3_column_text(stmt, 1))
            let version = String(cString: sqlite3_column_text(stmt, 2))
            if let collection = VectorCollection(rawValue: raw) {
                pairs.append((rowId, collection, version))
            }
        }
        return pairs
    }

    private func tableExists(_ table: String) throws -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func tableHasColumn(_ column: String, in table: String) throws -> Bool {
        guard try tableExists(table) else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: name) == column { return true }
        }
        return false
    }

    /// Clears all vector-derived tables while keeping the live SQLite handle
    /// valid. Use this for in-process resets; unlinking the database file while
    /// `db` is open leaves SQLite writing to a deleted vnode and subsequent
    /// inserts fail with `disk I/O error`.
    public func removeAllData() throws {
        try dbLock.withLock {
        try withTransaction {
            try exec("DELETE FROM vector_cluster_members;")
            try exec("DELETE FROM vector_clusters;")
            // `vector_cluster_runs` has no FK to `vectors`, so the DELETE below
            // does not cascade to it. It must be cleared explicitly: it stores
            // the cluster fingerprint's absolute vector-id watermark, and the
            // sqlite_sequence reset here restarts ids at 1. A surviving run row
            // would make every re-ingested id fall below the stale watermark,
            // so the worker's incremental path would see zero "new" vectors and
            // never rebuild the Meaning clusters (they'd render empty until the
            // stale full-refit age expired).
            try exec("DELETE FROM vector_cluster_runs;")
            try exec("DELETE FROM vector_frame_layout;")
            try exec("DELETE FROM vector_neighbors;")
            try exec("DELETE FROM vectors;")
            try exec("DELETE FROM message_semantic_visibility;")
            try exec("DELETE FROM sqlite_sequence WHERE name IN ('vectors', 'vector_clusters');")
        }
        try index?.removeAllData()
        }
    }

    /// Row ids of every vector belonging to `messageId`. Used by deletion sync
    /// to notify the constellation before the vector rows are removed.
    public func vectorIds(forMessageId messageId: String) throws -> [Int64] {
        let sql = "SELECT vector_id FROM vectors WHERE message_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    /// Run multiple statements atomically on the shared vector database.
    public func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try dbLock.withLock {
        try exec("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try exec("COMMIT;")
            return value
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        }
    }

    public func entityVectorRowId(kind: EntityKind, key: String) throws -> Int64? {
        let sql = "SELECT vector_id FROM vectors WHERE collection = ? AND entity_kind = ? AND entity_key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, VectorCollection.entity.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, kind.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 3, key, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    public func deleteEntityVector(vectorId: Int64) throws {
        try dbLock.withLock {
        let version = try entityVectorVersion(vectorId: vectorId)
        let sql = "DELETE FROM vectors WHERE vector_id = ? AND collection = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, vectorId)
        sqlite3_bind_text(stmt, 2, VectorCollection.entity.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        if let version {
            try? index?.remove(key: vectorId, collection: .entity, embeddingVersion: version)
        }
        }
    }

    /// Delete every persisted vector for one semantic entity identity.
    /// Multiple rows can survive a crash between vector insertion and the
    /// SwiftData entity update, so cleanup must not stop after the first match.
    @discardableResult
    public func deleteEntityVectors(kind: EntityKind, key: String) throws -> Int {
        try dbLock.withLock {
        let selectSQL = """
        SELECT vector_id, embedding_version
        FROM vectors
        WHERE collection = ? AND entity_kind = ? AND entity_key = ?;
        """
        var selectStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK,
              let selectStatement else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(selectStatement) }
        sqlite3_bind_text(selectStatement, 1, VectorCollection.entity.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(selectStatement, 2, kind.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(selectStatement, 3, key, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        var rows: [(id: Int64, version: String)] = []
        var selectResult = sqlite3_step(selectStatement)
        while selectResult == SQLITE_ROW {
            rows.append((
                id: sqlite3_column_int64(selectStatement, 0),
                version: String(cString: sqlite3_column_text(selectStatement, 1))
            ))
            selectResult = sqlite3_step(selectStatement)
        }
        guard selectResult == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard !rows.isEmpty else { return 0 }

        let deleteSQL = """
        DELETE FROM vectors
        WHERE collection = ? AND entity_kind = ? AND entity_key = ?;
        """
        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK,
              let deleteStatement else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(deleteStatement) }
        sqlite3_bind_text(deleteStatement, 1, VectorCollection.entity.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(deleteStatement, 2, kind.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(deleteStatement, 3, key, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        for row in rows {
            try? index?.remove(
                key: row.id,
                collection: .entity,
                embeddingVersion: row.version
            )
        }
        return rows.count
        }
    }

    private func entityVectorVersion(vectorId: Int64) throws -> String? {
        let sql = "SELECT embedding_version FROM vectors WHERE vector_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, vectorId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    public func distinctMessageIds(whereVersionNot version: String, limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }

        let sql = "SELECT DISTINCT message_id FROM vectors WHERE is_active = 1 AND embedding_version != ? LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, version, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var messageIds: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            messageIds.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return messageIds
    }

    /// Returns the distinct `Message.id` UUIDs whose vector rows fall in the
    /// supplied date range. Uses the `idx_vectors_received_at` index on
    /// `message_received_at` (Unix epoch seconds) for an O(log n) scan
    /// rather than the table scan SwiftData would do without an indexed
    /// attribute on `Message.receivedAt`. The Timeline data controller
    /// uses this to bound its SwiftData materialization to in-range rows.
    ///
    /// `message_id` is stored as `Message.id.uuidString` (see
    /// `EmbeddingOrchestrator.pendingVectors`). Rows whose `message_id` is
    /// not a valid UUID (entity vectors keyed by entity id, for example)
    /// are silently skipped — Timeline only consumes message UUIDs.
    public func messageIDsInDateRange(_ range: ClosedRange<Date>) throws -> Set<UUID> {
        let sql = "SELECT DISTINCT message_id FROM vectors WHERE is_active = 1 AND message_received_at BETWEEN ? AND ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, range.lowerBound.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, range.upperBound.timeIntervalSince1970)

        var ids: Set<UUID> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let raw = String(cString: cString)
            if let uuid = UUID(uuidString: raw) {
                ids.insert(uuid)
            }
        }
        return ids
    }

    /// The earliest and latest `message_received_at` (email date) among
    /// vector rows, optionally bounded to `range`. Passing `nil` returns the
    /// bounds over the entire store (the "All Time" span). Rides the same
    /// `idx_vectors_received_at` index as `messageIDsInDateRange`, so it is an
    /// O(log n) `MIN`/`MAX` probe rather than a table scan.
    ///
    /// The Timeline lens uses this to fit its layout (outer) range to the
    /// first → last email of the selected Moments window, so the ruler and
    /// minimap span exactly the timeframe in view. Returns `nil` when no
    /// in-range row carries a `message_received_at` value (empty window).
    public func receivedDateBounds(in range: ClosedRange<Date>?) throws -> (min: Date, max: Date)? {
        let sql: String
        if range == nil {
            sql = "SELECT MIN(message_received_at), MAX(message_received_at) FROM vectors WHERE is_active = 1 AND message_received_at IS NOT NULL;"
        } else {
            sql = "SELECT MIN(message_received_at), MAX(message_received_at) FROM vectors WHERE is_active = 1 AND message_received_at BETWEEN ? AND ?;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        if let range {
            sqlite3_bind_double(stmt, 1, range.lowerBound.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, range.upperBound.timeIntervalSince1970)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        // MIN/MAX over an empty set yield SQL NULL — guard both columns.
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL,
              sqlite3_column_type(stmt, 1) != SQLITE_NULL else { return nil }
        let lo = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        let hi = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        return (min: lo, max: hi)
    }

    // MARK: - Count

    public func count(collection: VectorCollection? = nil) throws -> Int {
        let sql: String
        if let collection {
            sql = "SELECT COUNT(*) FROM vectors WHERE is_active = 1 AND collection = '\(collection.rawValue)';"
        } else {
            sql = "SELECT COUNT(*) FROM vectors WHERE is_active = 1;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func count(collection: VectorCollection, embeddingVersion: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM vectors WHERE is_active = 1 AND collection = ? AND embedding_version = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, collection.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, embeddingVersion, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_step(stmt)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func indexCount(collection: VectorCollection, embeddingVersion: String) -> Int? {
        index?.count(collection: collection, embeddingVersion: embeddingVersion)
    }

    public func reconcileIndexIfAvailable() throws -> VectorIndexReconciler.Stats? {
        guard let index else { return nil }
        return try VectorIndexReconciler.reconcile(store: self, index: index)
    }

    public func saveIndexIfAvailable() throws {
        try index?.save()
    }

    /// (totalVectorRows, vectorRowsWithLayoutPosition). Used by the activity
    /// strip to surface the indexing step (step 5 of the embedding-then-
    /// place pipeline). Two queries, both index-friendly via the existing
    /// `idx_vectors_layout` partial index.
    public func placementCounts() throws -> (total: Int, placed: Int) {
        let total = try count(collection: nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM vectors WHERE is_active = 1 AND layout_x IS NOT NULL;",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        let placed = Int(sqlite3_column_int64(stmt, 0))
        return (total, placed)
    }

    /// (totalEmailNodes, placedEmailNodes). An email node is a distinct
    /// message represented by at least one renderable message vector row; a
    /// placed email node has coordinates in the Constellation render feed and
    /// can be hovered or clicked. This deliberately excludes `.style`
    /// training vectors and `.entity` actor vectors, whose `message_id`
    /// values are not one-to-one email-message IDs.
    public func emailNodeCounts() throws -> (total: Int, placed: Int) {
        let emailNodeCollections = "is_active = 1 AND collection IN ('\(VectorCollection.context.rawValue)', '\(VectorCollection.attachment.rawValue)')"
        let total = try distinctMessageCount(whereClause: emailNodeCollections)
        let placed = try distinctMessageCount(
            whereClause: """
            \(emailNodeCollections)
            AND layout_x IS NOT NULL
            AND layout_y IS NOT NULL
            AND layout_z IS NOT NULL
            """
        )
        return (total, placed)
    }

    private func distinctMessageCount(whereClause: String?) throws -> Int {
        var sql = "SELECT COUNT(DISTINCT message_id) FROM vectors"
        if let whereClause, !whereClause.isEmpty {
            sql += " WHERE \(whereClause)"
        }
        sql += ";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Vector ids that lack a 3-D position. Used by the scheduler's safety-
    /// net pass to seed `.index` jobs for vectors that were embedded but
    /// never indexed — which can happen if an `.embed` batch threw before
    /// reaching its post-batch sweep, or if the corpus was migrated from a
    /// pre-Constellation build that had no layout columns. Capped so a
    /// large backlog doesn't dominate one scheduler tick.
    public func unplacedVectorIds(limit: Int) throws -> [Int64] {
        try dbLock.withLock {
            var stmt: OpaquePointer?
            let sql = """
            SELECT vector_id FROM vectors
            WHERE is_active = 1 AND layout_x IS NULL
            ORDER BY
                CASE collection
                WHEN '\(VectorCollection.context.rawValue)' THEN 0
                WHEN '\(VectorCollection.attachment.rawValue)' THEN 1
                ELSE 2
                END,
                message_received_at DESC,
                vector_id
            LIMIT \(limit);
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var ids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(stmt, 0))
            }
            return ids
        }
    }

    /// Highest SQLite row id currently present in `vectors`. This is a cheap
    /// watermark used by the embedding pipeline to discover rows inserted by
    /// the just-finished batch without decoding every vector blob on the
    /// MainActor.
    public func maxVectorId() throws -> Int64 {
        try dbLock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(vector_id), 0) FROM vectors;",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_step(stmt)
            return sqlite3_column_int64(stmt, 0)
        }
    }

    /// Unplaced rows inserted after `vectorId`. Used after an embedding batch
    /// to enqueue layout work for only the new vectors, avoiding a full-table
    /// vector snapshot during interactive use.
    public func unplacedVectorIds(after vectorId: Int64) throws -> [Int64] {
        try dbLock.withLock {
            var stmt: OpaquePointer?
            let sql = """
            SELECT vector_id FROM vectors
            WHERE is_active = 1 AND vector_id > ? AND layout_x IS NULL
            ORDER BY vector_id;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, vectorId)
            var ids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(stmt, 0))
            }
            return ids
        }
    }

    /// Streams `(vector_id, vector, collection, embedding_version)` tuples for
    /// every row in the vectors table. Used by the reconciler to rebuild the
    /// ANN index without loading text payloads or metadata into memory.
    public func enumerateForIndex(_ body: (Int64, [Float], VectorCollection, String) throws -> Void) throws {
        let sql = "SELECT vector_id, vector, collection, embedding_version FROM vectors WHERE is_active = 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))
            let blobPtr = sqlite3_column_blob(stmt, 1)
            let vector = vectorFromBlob(blobPtr, byteCount: blobLen)
            guard !vector.isEmpty else { continue }
            let rawCollection = String(cString: sqlite3_column_text(stmt, 2))
            guard let collection = VectorCollection(rawValue: rawCollection) else { continue }
            let version = String(cString: sqlite3_column_text(stmt, 3))
            try body(rowId, vector, collection, version)
        }
    }

    /// Every collection/version partition represented in SQLite, including
    /// partitions whose rows are all inactive. The reconciler needs these to
    /// remove stale ANN keys even when there is no active row to enumerate.
    public func vectorIndexPartitions() throws -> [(VectorCollection, String)] {
        let sql = "SELECT DISTINCT collection, embedding_version FROM vectors;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var partitions: [(VectorCollection, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawCollection = sqlite3_column_text(stmt, 0),
                  let rawVersion = sqlite3_column_text(stmt, 1),
                  let collection = VectorCollection(rawValue: String(cString: rawCollection)) else {
                continue
            }
            partitions.append((collection, String(cString: rawVersion)))
        }
        return partitions
    }

    // MARK: - Layout state (Constellation mode)

    /// Writes a batch of 3-D layout positions into the `vectors` table,
    /// wrapped in a single `BEGIN IMMEDIATE` / `COMMIT` transaction so the
    /// update either lands atomically or not at all.
    public func updateLayoutBatch(
        _ positions: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)]
    ) throws {
        try updateLayoutRows(positions, arrivalTime: nil)
    }

    /// Writes layout positions and stamps a shared `arrival_time` in one
    /// transaction. Used by batched indexing so freshly placed nodes become
    /// visible to the "Now" constellation filter without a second write pass.
    public func updateLayoutAndArrivalBatch(
        _ positions: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)],
        at date: Date
    ) throws {
        try updateLayoutRows(positions, arrivalTime: date.timeIntervalSince1970)
    }

    private func updateLayoutRows(
        _ positions: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)],
        arrivalTime: TimeInterval?
    ) throws {
        try dbLock.withLock {
        guard !positions.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        var committed = false
        defer {
            if !committed {
                // Best-effort rollback on throw; we already surfaced the real
                // error up the stack.
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }
        let sql: String
        if arrivalTime == nil {
            sql = """
            UPDATE vectors SET layout_x = ?, layout_y = ?, layout_z = ?, last_move_magnitude = ?
            WHERE vector_id = ?;
            """
        } else {
            sql = """
            UPDATE vectors SET layout_x = ?, layout_y = ?, layout_z = ?, last_move_magnitude = ?, arrival_time = ?
            WHERE vector_id = ?;
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for p in positions {
            sqlite3_bind_double(stmt, 1, Double(p.xyz.x))
            sqlite3_bind_double(stmt, 2, Double(p.xyz.y))
            sqlite3_bind_double(stmt, 3, Double(p.xyz.z))
            sqlite3_bind_double(stmt, 4, Double(p.moveMagnitude))
            if let arrivalTime {
                sqlite3_bind_double(stmt, 5, arrivalTime)
                sqlite3_bind_int64(stmt, 6, p.vectorId)
            } else {
                sqlite3_bind_int64(stmt, 5, p.vectorId)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(stmt)
        }
        try exec("COMMIT;")
        committed = true
        }
    }

    /// Populate `message_received_at` for vector rows that have no value yet,
    /// looking up each row's `messageId` in the supplied `[messageId: date]`
    /// map. No-op for rows where the map has no entry.
    public func backfillMessageReceivedAt(_ dateByMessageId: [String: TimeInterval]) throws -> Int {
        try dbLock.withLock {
        guard !dateByMessageId.isEmpty else { return 0 }
        try exec("BEGIN;")
        do {
            let sql = "UPDATE vectors SET message_received_at = ? WHERE message_id = ? AND message_received_at IS NULL;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var updated = 0
            for (messageId, timestamp) in dateByMessageId {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_double(stmt, 1, timestamp)
                sqlite3_bind_text(stmt, 2, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                updated += Int(sqlite3_changes(db))
            }
            try exec("COMMIT;")
            return updated
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        }
    }

    /// Rewrites `message_received_at` for known message rows, including
    /// setting it back to NULL when the source message has no actual email
    /// date. Runs at launch to repair legacy rows and any prior ingestion-time
    /// fallbacks; ranged Moments filters are strict about NULL dates.
    public func repairMessageReceivedAt(_ repairs: [VectorMessageDateRepair]) throws -> Int {
        try dbLock.withLock {
        guard !repairs.isEmpty else { return 0 }
        try exec("BEGIN;")
        do {
            let sql = "UPDATE vectors SET message_received_at = ? WHERE message_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var updated = 0
            for repair in repairs {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                if let timestamp = repair.timestamp {
                    sqlite3_bind_double(stmt, 1, timestamp)
                } else {
                    sqlite3_bind_null(stmt, 1)
                }
                sqlite3_bind_text(stmt, 2, repair.messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                updated += Int(sqlite3_changes(db))
            }
            try exec("COMMIT;")
            return updated
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        }
    }

    /// Stamps `arrival_time` on a vector row. Used by the Constellation layout
    /// pipeline to trigger the "ignition" emissive boost on newly-placed nodes.
    public func markArrivalTime(_ vectorId: Int64, at date: Date) throws {
        try dbLock.withLock {
        let sql = "UPDATE vectors SET arrival_time = ? WHERE vector_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, vectorId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        }
    }

    /// Fetches every vector that has been laid out in 3-space, optionally
    /// narrowed by a `VectorFilter`. Filters expressible on the `vectors`
    /// table alone (collection, message date range) are pushed down as SQL;
    /// cross-table predicates are left to in-memory filtering by callers.
    public func vectorsWithLayout(filter: VectorFilter?, limit: Int) throws -> [VectorRecord] {
        var clauses: [String] = ["is_active = 1", "layout_x IS NOT NULL"]
        if let filter {
            clauses.append(contentsOf: filter.sqlClauses())
        }
        let whereSQL = clauses.joined(separator: " AND ")
        let sql = "SELECT vector_id, message_id, collection, chunk_index, embedding_version, vector, text_payload, metadata_json, created_at, layout_x, layout_y, layout_z, arrival_time, last_move_magnitude, message_received_at, entity_kind, entity_key, entity_score FROM vectors WHERE \(whereSQL) LIMIT \(limit);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [VectorRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(try rowToRecord(stmt))
        }
        return rows
    }

    /// Lightweight Constellation render feed. Unlike `vectorsWithLayout`, this
    /// intentionally does not select the embedding blob or text payload, so
    /// viewport planning can hard-gate and aggregate large corpora without
    /// decoding vectors the renderer will never draw.
    public func renderRowsWithLayout(filter: VectorFilter?, limit: Int) throws -> [VectorRenderSourceRow] {
        var clauses: [String] = [
            "is_active = 1",
            "layout_x IS NOT NULL",
            "layout_y IS NOT NULL",
            "layout_z IS NOT NULL"
        ]
        if let filter {
            clauses.append(contentsOf: filter.sqlClauses())
        }
        let whereSQL = clauses.joined(separator: " AND ")
        let sql = """
        SELECT vector_id, message_id, collection, chunk_index,
               layout_x, layout_y, layout_z,
               arrival_time, last_move_magnitude, message_received_at,
               entity_kind, entity_score
        FROM vectors
        WHERE \(whereSQL)
        LIMIT \(limit);
        """
        return try dbLock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var rows: [VectorRenderSourceRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(try renderRow(from: stmt))
            }
            return rows
        }
    }

    /// Distance from each selected persisted cluster's anchor to its
    /// farthest placed context-summary member. Frame-specific positions take
    /// precedence over each vector's default layout, matching the visible
    /// render path; vectors without a settled frame position retain that
    /// default-layout fallback. Meaning presentation packing uses this
    /// unfiltered source envelope so Moments and status filters cannot change
    /// the transform of surviving nodes. Only member coordinates are read,
    /// so a packet build never materializes the clustered corpus as render
    /// rows. Clusters without a placed member are absent from the result.
    /// The query is read-only and never changes membership.
    public func clusteredContextSourceRadii(
        frame: FrameKey,
        anchorByClusterId: [Int64: SIMD3<Float>]
    ) throws -> [Int64: Float] {
        guard !anchorByClusterId.isEmpty else { return [:] }
        let orderedClusterIds = anchorByClusterId.keys.sorted()
        let placeholders = Array(repeating: "?", count: orderedClusterIds.count)
            .joined(separator: ",")
        let sql = """
        SELECT m.cluster_id,
               COALESCE(f.layout_x, v.layout_x),
               COALESCE(f.layout_y, v.layout_y),
               COALESCE(f.layout_z, v.layout_z)
        FROM vector_cluster_members AS m
        JOIN vector_clusters AS c ON c.cluster_id = m.cluster_id
        JOIN vectors AS v ON v.vector_id = m.vector_id
        LEFT JOIN vector_frame_layout AS f
          ON f.vector_id = m.vector_id AND f.frame_key = c.frame_key
        WHERE c.frame_key = ?
          AND m.cluster_id IN (\(placeholders))
          AND v.is_active = 1
          AND v.collection = ?
          AND v.chunk_index = 0
          AND v.layout_x IS NOT NULL
          AND v.layout_y IS NOT NULL
          AND v.layout_z IS NOT NULL;
        """
        return try dbLock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            for (offset, clusterId) in orderedClusterIds.enumerated() {
                sqlite3_bind_int64(stmt, Int32(offset + 2), clusterId)
            }
            sqlite3_bind_text(
                stmt,
                Int32(orderedClusterIds.count + 2),
                VectorCollection.context.rawValue,
                -1,
                SQLITE_TRANSIENT_DESTRUCTOR
            )

            var radiusByClusterId: [Int64: Float] = [:]
            radiusByClusterId.reserveCapacity(orderedClusterIds.count)
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                let clusterId = sqlite3_column_int64(stmt, 0)
                guard let anchor = anchorByClusterId[clusterId] else { continue }
                let delta = SIMD3<Float>(
                    Float(sqlite3_column_double(stmt, 1)),
                    Float(sqlite3_column_double(stmt, 2)),
                    Float(sqlite3_column_double(stmt, 3))
                ) - anchor
                let distance = (delta * delta).sum().squareRoot()
                radiusByClusterId[clusterId] = max(radiusByClusterId[clusterId] ?? 0, distance)
            }
            return radiusByClusterId
        }
    }

    // MARK: - Cosine similarity search

    public func search(
        query: [Float],
        collection: VectorCollection,
        topK: Int,
        embeddingVersion: String
    ) throws -> [SearchResult] {
        guard topK > 0 else { return [] }
        guard let index else {
            return try bruteForceSearch(query: query, collection: collection, topK: topK, embeddingVersion: embeddingVersion)
        }

        let matches = try index.search(query: query, collection: collection, embeddingVersion: embeddingVersion, k: topK)
        guard matches.isEmpty == false else { return [] }

        let records = try hydrate(vectorIds: matches.map(\.key))
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.vectorId, $0) })
        return matches.compactMap { match -> SearchResult? in
            guard let record = byId[match.key] else { return nil }
            return SearchResult(record: record, score: 1.0 - match.distance)
        }
    }

    public func search(
        query: [Float],
        collection: VectorCollection,
        topK: Int
    ) throws -> [SearchResult] {
        let versions = try uniqueEmbeddingVersions(collection: collection)
        if versions.isEmpty { return [] }
        guard let only = versions.first, versions.count == 1 else {
            throw VectorStoreError.prepareFailed(
                "search() called without embeddingVersion but corpus has \(versions.count) versions"
            )
        }
        return try search(query: query, collection: collection, topK: topK, embeddingVersion: only)
    }

    private func uniqueEmbeddingVersions(collection: VectorCollection) throws -> [String] {
        let sql = "SELECT DISTINCT embedding_version FROM vectors WHERE is_active = 1 AND collection = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, collection.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        var versions: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            versions.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return versions
    }

    private func bruteForceSearch(
        query: [Float],
        collection: VectorCollection,
        topK: Int,
        embeddingVersion: String
    ) throws -> [SearchResult] {
        let sql = "SELECT vector_id, message_id, collection, chunk_index, embedding_version, vector, text_payload, metadata_json, created_at, layout_x, layout_y, layout_z, arrival_time, last_move_magnitude, message_received_at, entity_kind, entity_key, entity_score FROM vectors WHERE is_active = 1 AND collection = ? AND embedding_version = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collection.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, embeddingVersion, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        // Precompute the query norm once; only the candidate norm varies per row.
        let queryNormSq = vDSP.sumOfSquares(query)
        let queryNorm = queryNormSq.squareRoot()
        guard queryNorm > 0 else { return [] }

        var scored: [(record: VectorRecord, score: Float)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = try rowToRecord(stmt)
            let score = VectorStore.cosineScore(
                query: query,
                queryNorm: queryNorm,
                candidate: record.vector
            )
            scored.append((record, score))
        }

        scored.sort { $0.score > $1.score }
        let top = scored.prefix(topK)
        return top.map { SearchResult(record: $0.record, score: $0.score) }
    }

    public func hydrate(vectorIds: [Int64]) throws -> [VectorRecord] {
        guard vectorIds.isEmpty == false else { return [] }

        let placeholders = Array(repeating: "?", count: vectorIds.count).joined(separator: ",")
        let sql = "SELECT vector_id, message_id, collection, chunk_index, embedding_version, vector, text_payload, metadata_json, created_at, layout_x, layout_y, layout_z, arrival_time, last_move_magnitude, message_received_at, entity_kind, entity_key, entity_score FROM vectors WHERE vector_id IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (index, id) in vectorIds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }

        var rows: [VectorRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(try rowToRecord(stmt))
        }
        var order: [Int64: Int] = [:]
        for (index, id) in vectorIds.enumerated() where order[id] == nil {
            order[id] = index
        }
        rows.sort {
            (order[$0.vectorId] ?? Int.max) < (order[$1.vectorId] ?? Int.max)
        }
        return rows
    }

    /// Display-surface variant of `hydrate(vectorIds:)`: identical rows minus
    /// the two heavyweight columns — the embedding BLOB and the chunk text
    /// payload. The Constellation host keeps a per-packet cache of every
    /// visible node's record purely for `messageId` / layout / collection
    /// lookups (hover routing, lock entry, new-star tracking); hauling each
    /// row's multi-KB vector and full text through SQLite for that cache is
    /// pure waste. Returned records carry `vector: []` and `textPayload: ""`
    /// — callers that need either field must use `hydrate(vectorIds:)`.
    public func hydrateDisplayMetadata(vectorIds: [Int64]) throws -> [VectorRecord] {
        guard vectorIds.isEmpty == false else { return [] }

        let placeholders = Array(repeating: "?", count: vectorIds.count).joined(separator: ",")
        let sql = "SELECT vector_id, message_id, collection, chunk_index, embedding_version, metadata_json, created_at, layout_x, layout_y, layout_z, arrival_time, last_move_magnitude, message_received_at, entity_kind, entity_key, entity_score FROM vectors WHERE vector_id IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (index, id) in vectorIds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }

        var rows: [VectorRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(try displayMetadataRowToRecord(stmt))
        }
        var order: [Int64: Int] = [:]
        for (index, id) in vectorIds.enumerated() where order[id] == nil {
            order[id] = index
        }
        rows.sort {
            (order[$0.vectorId] ?? Int.max) < (order[$1.vectorId] ?? Int.max)
        }
        return rows
    }

    public func countMessages(filter: FilterSpec) throws -> Int {
        if let allowedMessageIds = filter.allowedMessageIds, allowedMessageIds.isEmpty {
            return 0
        }

        let join = " JOIN message_filter_metadata m ON m.message_id = v.message_id"
        var clauses = ["v.is_active = 1"]
        let whereFragment = filter.sqlWhereFragment()
        if !whereFragment.isEmpty {
            clauses.append(whereFragment)
        }
        if let allowedMessageIds = filter.allowedMessageIds {
            let placeholders = Array(repeating: "?", count: allowedMessageIds.count).joined(separator: ",")
            clauses.append("v.message_id IN (\(placeholders))")
        }

        var sql = "SELECT COUNT(DISTINCT v.message_id) FROM vectors v\(join)"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += ";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        try bind(filter.parameters, to: stmt, startingAt: &idx)
        if let allowedMessageIds = filter.allowedMessageIds {
            for messageId in allowedMessageIds {
                sqlite3_bind_text(stmt, idx, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                idx += 1
            }
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func enumerateMessageIds(
        filter: FilterSpec,
        orderBy: ScopeOrder = .receivedDesc,
        limit: Int? = nil
    ) throws -> [String] {
        if let allowedMessageIds = filter.allowedMessageIds, allowedMessageIds.isEmpty {
            return []
        }
        if let limit, limit <= 0 {
            return []
        }

        let join = " JOIN message_filter_metadata m ON m.message_id = v.message_id"
        let sortDateExpression = "COALESCE(MAX(m.received_at), MAX(v.message_received_at), 0)"
        let orderClause: String
        switch orderBy {
        case .receivedDesc:
            orderClause = "\(sortDateExpression) DESC, MIN(v.vector_id) ASC"
        case .receivedAsc:
            orderClause = "\(sortDateExpression) ASC, MIN(v.vector_id) ASC"
        case .messageIdAsc:
            orderClause = "v.message_id ASC"
        }

        var clauses = ["v.is_active = 1"]
        let whereFragment = filter.sqlWhereFragment()
        if !whereFragment.isEmpty {
            clauses.append(whereFragment)
        }
        if let allowedMessageIds = filter.allowedMessageIds {
            let placeholders = Array(repeating: "?", count: allowedMessageIds.count).joined(separator: ",")
            clauses.append("v.message_id IN (\(placeholders))")
        }

        var sql = """
        SELECT v.message_id
        FROM vectors v\(join)
        """
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " GROUP BY v.message_id ORDER BY \(orderClause)"
        if limit != nil {
            sql += " LIMIT ?"
        }
        sql += ";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        try bind(filter.parameters, to: stmt, startingAt: &idx)
        if let allowedMessageIds = filter.allowedMessageIds {
            for messageId in allowedMessageIds {
                sqlite3_bind_text(stmt, idx, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                idx += 1
            }
        }
        if let limit {
            sqlite3_bind_int64(stmt, idx, Int64(limit))
        }

        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return rows
    }

    /// Vector IDs across the supplied message IDs that pass the filter.
    public func vectorIds(forMessageIds messageIds: [String], filter: FilterSpec, limit: Int) throws -> [Int64] {
        guard !messageIds.isEmpty, limit > 0 else { return [] }

        let scopedMessageIds: [String]
        if let allowedMessageIds = filter.allowedMessageIds {
            guard !allowedMessageIds.isEmpty else { return [] }
            let allowed = Set(allowedMessageIds)
            scopedMessageIds = messageIds.filter { allowed.contains($0) }
            guard !scopedMessageIds.isEmpty else { return [] }
        } else {
            scopedMessageIds = messageIds
        }

        let inMessages = Array(repeating: "?", count: scopedMessageIds.count).joined(separator: ",")
        let join = filter.requiresMessageMetadata
            ? " JOIN message_filter_metadata m ON m.message_id = v.message_id"
            : ""
        let whereFragment = filter.sqlWhereFragment()
        var sql = """
        SELECT v.vector_id, v.message_id
        FROM vectors v\(join)
        WHERE v.message_id IN (\(inMessages))
          AND v.is_active = 1
        """
        if !whereFragment.isEmpty {
            sql += " AND \(whereFragment)"
        }
        sql += " ORDER BY v.vector_id;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for messageId in scopedMessageIds {
            sqlite3_bind_text(stmt, idx, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            idx += 1
        }
        try bind(filter.parameters, to: stmt, startingAt: &idx)

        var idsByMessage: [String: [Int64]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let vectorId = sqlite3_column_int64(stmt, 0)
            let messageId = String(cString: sqlite3_column_text(stmt, 1))
            idsByMessage[messageId, default: []].append(vectorId)
        }

        var out: [Int64] = []
        out.reserveCapacity(min(limit, scopedMessageIds.count))
        for messageId in scopedMessageIds {
            for vectorId in idsByMessage[messageId] ?? [] {
                guard out.count < limit else { return out }
                out.append(vectorId)
            }
        }
        return out
    }

    /// One representative vector id per message (the lowest `vector_id`,
    /// deterministically chosen), for the supplied messages that pass the
    /// filter. Used by literal search to map ranked message hits to a single
    /// node the camera can warp to.
    public func representativeVectorIds(
        forMessageIds messageIds: [String],
        filter: FilterSpec
    ) throws -> [String: Int64] {
        guard !messageIds.isEmpty else { return [:] }

        let scopedMessageIds: [String]
        if let allowedMessageIds = filter.allowedMessageIds {
            guard !allowedMessageIds.isEmpty else { return [:] }
            let allowed = Set(allowedMessageIds)
            scopedMessageIds = messageIds.filter { allowed.contains($0) }
            guard !scopedMessageIds.isEmpty else { return [:] }
        } else {
            scopedMessageIds = messageIds
        }

        let inMessages = Array(repeating: "?", count: scopedMessageIds.count).joined(separator: ",")
        let join = filter.requiresMessageMetadata
            ? " JOIN message_filter_metadata m ON m.message_id = v.message_id"
            : ""
        let whereFragment = filter.sqlWhereFragment()
        var sql = """
        SELECT v.message_id, MIN(v.vector_id)
        FROM vectors v\(join)
        WHERE v.message_id IN (\(inMessages))
          AND v.is_active = 1
        """
        if !whereFragment.isEmpty {
            sql += " AND \(whereFragment)"
        }
        sql += " GROUP BY v.message_id;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for messageId in scopedMessageIds {
            sqlite3_bind_text(stmt, idx, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            idx += 1
        }
        try bind(filter.parameters, to: stmt, startingAt: &idx)

        var out: [String: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = String(cString: sqlite3_column_text(stmt, 0))
            out[messageId] = sqlite3_column_int64(stmt, 1)
        }
        return out
    }

    /// Subset of `candidateIds` that passes the filter.
    public func filterVectorIds(_ candidateIds: [Int64], filter: FilterSpec) throws -> Set<Int64> {
        guard !candidateIds.isEmpty else { return [] }

        let inIds = Array(repeating: "?", count: candidateIds.count).joined(separator: ",")
        let join = filter.requiresMessageMetadata
            ? " JOIN message_filter_metadata m ON m.message_id = v.message_id"
            : ""
        let whereFragment = filter.sqlWhereFragment()
        var sql = """
        SELECT v.vector_id
        FROM vectors v\(join)
        WHERE v.vector_id IN (\(inIds))
          AND v.is_active = 1
        """
        if !whereFragment.isEmpty {
            sql += " AND \(whereFragment)"
        }
        sql += ";"

        let result = try runVectorIdQuery(sql: sql, intBindings: candidateIds, filterParams: filter.parameters)
        guard let allowedMessageIds = filter.allowedMessageIds else {
            return Set(result)
        }
        guard !allowedMessageIds.isEmpty else { return [] }

        let allowed = Set(allowedMessageIds)
        let messageIdByVectorId = try messageIds(for: result)
        return Set(result.filter { vectorId in
            guard let messageId = messageIdByVectorId[vectorId] else { return false }
            return allowed.contains(messageId)
        })
    }

    private func runVectorIdQuery(
        sql: String,
        textBindings: [String] = [],
        intBindings: [Int64] = [],
        filterParams: [SQLBindable]
    ) throws -> [Int64] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for value in textBindings {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            idx += 1
        }
        for value in intBindings {
            sqlite3_bind_int64(stmt, idx, value)
            idx += 1
        }
        try bind(filterParams, to: stmt, startingAt: &idx)

        var rows: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(sqlite3_column_int64(stmt, 0))
        }
        return rows
    }

    private func bind(_ params: [SQLBindable], to stmt: OpaquePointer, startingAt idx: inout Int32) throws {
        for param in params {
            switch param {
            case .text(let value):
                sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .integer(let value):
                sqlite3_bind_int64(stmt, idx, value)
            case .real(let value):
                sqlite3_bind_double(stmt, idx, value)
            case .null:
                sqlite3_bind_null(stmt, idx)
            }
            idx += 1
        }
    }

    // MARK: - Cosine similarity

    /// Accelerate-backed cosine similarity. `vDSP.dot` and `vDSP.sumOfSquares`
    /// are SIMD-vectorized on Apple Silicon, typically 5–15× faster than the
    /// scalar Swift loop for 128–512-dimensional embeddings.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b)
        let normA = vDSP.sumOfSquares(a).squareRoot()
        let normB = vDSP.sumOfSquares(b).squareRoot()
        let denom = normA * normB
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Hot-path variant for `search(...)` where the query norm has already
    /// been computed once for the whole batch. Saves one vDSP.sumOfSquares +
    /// one sqrt per candidate.
    private static func cosineScore(query: [Float], queryNorm: Float, candidate: [Float]) -> Float {
        guard query.count == candidate.count, !candidate.isEmpty else { return 0 }
        let dot = vDSP.dot(query, candidate)
        let candidateNorm = vDSP.sumOfSquares(candidate).squareRoot()
        guard candidateNorm > 0 else { return 0 }
        return dot / (queryNorm * candidateNorm)
    }

    // MARK: - Helpers

    private func rowToRecord(_ stmt: OpaquePointer) throws -> VectorRecord {
        let vectorId = sqlite3_column_int64(stmt, 0)
        let messageId = String(cString: sqlite3_column_text(stmt, 1))
        let collectionRaw = String(cString: sqlite3_column_text(stmt, 2))
        let chunkIndex = Int(sqlite3_column_int64(stmt, 3))
        let embeddingVersion = String(cString: sqlite3_column_text(stmt, 4))

        let blobPtr = sqlite3_column_blob(stmt, 5)
        let blobBytes = Int(sqlite3_column_bytes(stmt, 5))
        let vector = vectorFromBlob(blobPtr, byteCount: blobBytes)

        let textPayload = String(cString: sqlite3_column_text(stmt, 6))
        let metadataJSON = String(cString: sqlite3_column_text(stmt, 7))
        let createdAt = String(cString: sqlite3_column_text(stmt, 8))

        let layoutX: Float? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 9))
        let layoutY: Float? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 10))
        let layoutZ: Float? = sqlite3_column_type(stmt, 11) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 11))
        let arrival: TimeInterval? = sqlite3_column_type(stmt, 12) == SQLITE_NULL
            ? nil : sqlite3_column_double(stmt, 12)
        let lastMove: Float? = sqlite3_column_type(stmt, 13) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 13))
        let messageReceivedAt: TimeInterval? = sqlite3_column_type(stmt, 14) == SQLITE_NULL
            ? nil : sqlite3_column_double(stmt, 14)
        let entityKindRaw: String? = sqlite3_column_type(stmt, 15) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 15))
        let entityKind = entityKindRaw.flatMap(EntityKind.init(rawValue:))
        let entityKey: String? = sqlite3_column_type(stmt, 16) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 16))
        let entityScore: Float? = sqlite3_column_type(stmt, 17) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 17))

        guard let collection = VectorCollection(rawValue: collectionRaw) else {
            throw VectorStoreError.prepareFailed("Unknown collection value: \(collectionRaw)")
        }

        return VectorRecord(
            vectorId: vectorId,
            messageId: messageId,
            collection: collection,
            chunkIndex: chunkIndex,
            embeddingVersion: embeddingVersion,
            vector: vector,
            textPayload: textPayload,
            metadataJSON: metadataJSON,
            createdAt: createdAt,
            layoutX: layoutX,
            layoutY: layoutY,
            layoutZ: layoutZ,
            arrivalTime: arrival,
            lastMoveMagnitude: lastMove,
            messageReceivedAt: messageReceivedAt,
            entityKind: entityKind,
            entityKey: entityKey,
            entityScore: entityScore
        )
    }

    /// Decodes a `hydrateDisplayMetadata` row. Column indices are shifted
    /// against `rowToRecord` because the SELECT omits `vector` and
    /// `text_payload`; both fields are filled with their empty sentinels.
    private func displayMetadataRowToRecord(_ stmt: OpaquePointer) throws -> VectorRecord {
        let vectorId = sqlite3_column_int64(stmt, 0)
        let messageId = String(cString: sqlite3_column_text(stmt, 1))
        let collectionRaw = String(cString: sqlite3_column_text(stmt, 2))
        let chunkIndex = Int(sqlite3_column_int64(stmt, 3))
        let embeddingVersion = String(cString: sqlite3_column_text(stmt, 4))
        let metadataJSON = String(cString: sqlite3_column_text(stmt, 5))
        let createdAt = String(cString: sqlite3_column_text(stmt, 6))

        let layoutX: Float? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 7))
        let layoutY: Float? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 8))
        let layoutZ: Float? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 9))
        let arrival: TimeInterval? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
            ? nil : sqlite3_column_double(stmt, 10)
        let lastMove: Float? = sqlite3_column_type(stmt, 11) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 11))
        let messageReceivedAt: TimeInterval? = sqlite3_column_type(stmt, 12) == SQLITE_NULL
            ? nil : sqlite3_column_double(stmt, 12)
        let entityKindRaw: String? = sqlite3_column_type(stmt, 13) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 13))
        let entityKind = entityKindRaw.flatMap(EntityKind.init(rawValue:))
        let entityKey: String? = sqlite3_column_type(stmt, 14) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 14))
        let entityScore: Float? = sqlite3_column_type(stmt, 15) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 15))

        guard let collection = VectorCollection(rawValue: collectionRaw) else {
            throw VectorStoreError.prepareFailed("Unknown collection value: \(collectionRaw)")
        }

        return VectorRecord(
            vectorId: vectorId,
            messageId: messageId,
            collection: collection,
            chunkIndex: chunkIndex,
            embeddingVersion: embeddingVersion,
            vector: [],
            textPayload: "",
            metadataJSON: metadataJSON,
            createdAt: createdAt,
            layoutX: layoutX,
            layoutY: layoutY,
            layoutZ: layoutZ,
            arrivalTime: arrival,
            lastMoveMagnitude: lastMove,
            messageReceivedAt: messageReceivedAt,
            entityKind: entityKind,
            entityKey: entityKey,
            entityScore: entityScore
        )
    }

    private func renderRow(from stmt: OpaquePointer) throws -> VectorRenderSourceRow {
        let collectionRaw = String(cString: sqlite3_column_text(stmt, 2))
        guard let collection = VectorCollection(rawValue: collectionRaw) else {
            throw VectorStoreError.prepareFailed("Unknown collection value: \(collectionRaw)")
        }
        let arrival: TimeInterval? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
            ? nil : sqlite3_column_double(stmt, 7)
        let move: Float = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? 0 : Float(sqlite3_column_double(stmt, 8))
        let received: TimeInterval? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
            ? nil : sqlite3_column_double(stmt, 9)
        let entityKind: EntityKind?
        if sqlite3_column_type(stmt, 10) == SQLITE_NULL {
            entityKind = nil
        } else {
            entityKind = EntityKind(rawValue: String(cString: sqlite3_column_text(stmt, 10)))
        }
        let entityScore: Float? = sqlite3_column_type(stmt, 11) == SQLITE_NULL
            ? nil : Float(sqlite3_column_double(stmt, 11))
        return VectorRenderSourceRow(
            vectorId: sqlite3_column_int64(stmt, 0),
            messageId: String(cString: sqlite3_column_text(stmt, 1)),
            collection: collection,
            chunkIndex: Int(sqlite3_column_int(stmt, 3)),
            layout: SIMD3<Float>(
                Float(sqlite3_column_double(stmt, 4)),
                Float(sqlite3_column_double(stmt, 5)),
                Float(sqlite3_column_double(stmt, 6))
            ),
            arrivalTime: arrival,
            lastMoveMagnitude: move,
            messageReceivedAt: received,
            entityKind: entityKind,
            entityScore: entityScore
        )
    }

    private func finiteVector(_ vector: [Float]) -> [Float] {
        guard vector.contains(where: { !$0.isFinite }) else { return vector }
        return vector.map { $0.isFinite ? $0 : 0 }
    }

    private func validatedVector(_ vector: [Float]) throws -> [Float] {
        let sanitized = finiteVector(vector)
        let normSquared = sanitized.reduce(Float(0)) { partial, value in
            partial + value * value
        }
        guard normSquared > 1e-12 else {
            throw VectorStoreError.nearZeroVectorNorm(normSquared: normSquared)
        }
        return sanitized
    }

    private func vectorFromBlob(_ blobPtr: UnsafeRawPointer?, byteCount: Int) -> [Float] {
        guard let blobPtr, byteCount > 0 else { return [] }
        let vector = Array(UnsafeBufferPointer(
            start: blobPtr.assumingMemoryBound(to: Float.self),
            count: byteCount / MemoryLayout<Float>.size
        ))
        return finiteVector(vector)
    }

    private func vectorToData(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Layout pipeline helpers
//
// These helpers are consumed by `LayoutOrchestrator` (OhiaML). They live on
// `VectorStore` so the SQLite-handle access stays encapsulated in OhiaCore.
// The shape (`RawVec`: vector + 3-D position) is deliberately narrower than
// `VectorRecord` to avoid copying text payloads and metadata JSON through the
// hot-path layout loop, which may run over tens of thousands of rows.

extension VectorStore {

    public struct RawVec: Sendable {
        public let id: Int64
        public let vec: [Float]
        public let position: SIMD3<Float>?
        public var hasPlacedLayout: Bool { position != nil }

        public init(id: Int64, vec: [Float], position: SIMD3<Float>?) {
            self.id = id
            self.vec = vec
            self.position = position
        }
    }

    /// Every row in `vectors`, decoded as the minimal layout tuple
    /// (id, embedding vector, 3-D position-or-nil). `position` is nil when any
    /// of the three layout columns is NULL — i.e. the row has never been
    /// seeded by the layout pipeline yet.
    public func allVectorsRaw() throws -> [RawVec] {
        let sql = "SELECT vector_id, vector, layout_x, layout_y, layout_z FROM vectors WHERE is_active = 1;"
        return try rawVectors(sql: sql)
    }

    /// Minimal layout rows for vectors that already have a persisted position.
    public func placedVectorsRaw() throws -> [RawVec] {
        let sql = """
        SELECT vector_id, vector, layout_x, layout_y, layout_z
        FROM vectors
        WHERE is_active = 1
          AND layout_x IS NOT NULL AND layout_y IS NOT NULL AND layout_z IS NOT NULL;
        """
        return try rawVectors(sql: sql)
    }

    /// One representative placed semantic vector per message. The context
    /// collection's chunk 0 is the summary/metadata vector created first by
    /// the embedding pipeline, so it is the stable message-level identity to
    /// use for visible Meaning clusters.
    public func placedContextSummaryVectorsRaw() throws -> [RawVec] {
        let sql = """
        SELECT vector_id, vector, layout_x, layout_y, layout_z
        FROM vectors
        WHERE is_active = 1
          AND collection = '\(VectorCollection.context.rawValue)'
          AND chunk_index = 0
          AND layout_x IS NOT NULL
          AND layout_y IS NOT NULL
          AND layout_z IS NOT NULL
        ORDER BY vector_id;
        """
        return try rawVectors(sql: sql)
    }

    public func placedContextSummaryVectorCount() throws -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM vectors
        WHERE is_active = 1
          AND collection = ?
          AND chunk_index = 0
          AND layout_x IS NOT NULL
          AND layout_y IS NOT NULL
          AND layout_z IS NOT NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, VectorCollection.context.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func clusterCount(frame: FrameKey) throws -> Int {
        let sql = "SELECT COUNT(*) FROM vector_clusters WHERE frame_key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Minimal layout rows for a specific vector-id set.
    public func vectorsRaw(ids: [Int64]) throws -> [RawVec] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        SELECT vector_id, vector, layout_x, layout_y, layout_z
        FROM vectors
        WHERE is_active = 1
          AND vector_id IN (\(placeholders));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(1 + i), id)
        }
        var out: [RawVec] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(rawVec(from: stmt))
        }
        return out
    }

    private func rawVectors(sql: String) throws -> [RawVec] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [RawVec] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(rawVec(from: stmt))
        }
        return out
    }

    private func rawVec(from stmt: OpaquePointer) -> RawVec {
        let id = sqlite3_column_int64(stmt, 0)
        let blobLen = Int(sqlite3_column_bytes(stmt, 1))
        let blobPtr = sqlite3_column_blob(stmt, 1)
        let vec = vectorFromBlob(blobPtr, byteCount: blobLen)
        let pos: SIMD3<Float>?
        if sqlite3_column_type(stmt, 2) == SQLITE_NULL
            || sqlite3_column_type(stmt, 3) == SQLITE_NULL
            || sqlite3_column_type(stmt, 4) == SQLITE_NULL {
            pos = nil
        } else {
            pos = SIMD3<Float>(
                Float(sqlite3_column_double(stmt, 2)),
                Float(sqlite3_column_double(stmt, 3)),
                Float(sqlite3_column_double(stmt, 4))
            )
        }
        return RawVec(id: id, vec: vec, position: pos)
    }

    /// Maps `vector_id` → `message_id` for the given set. Used by the
    /// app-layer frame edge provider to join embedded vectors to SwiftData
    /// `Message` rows.
    public func messageIds(for vectorIds: [Int64]) throws -> [Int64: String] {
        guard !vectorIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: vectorIds.count).joined(separator: ",")
        let sql = "SELECT vector_id, message_id FROM vectors WHERE vector_id IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in vectorIds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(1 + i), id)
        }
        var out: [Int64: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let vid = sqlite3_column_int64(stmt, 0)
            out[vid] = String(cString: sqlite3_column_text(stmt, 1))
        }
        return out
    }

    /// Counts vectors per message broken down by collection, excluding the
    /// `.style` collection. The constellation hover treats chunks,
    /// attachments, and entities as the node's "moons" and colors them per
    /// their collection; style vectors are training-side artifacts and have
    /// no presence in the rendered scene.
    public func messageVectorCounts() throws -> [String: MessageVectorCountBreakdown] {
        let sql = "SELECT message_id, collection, COUNT(*) FROM vectors WHERE collection != ? GROUP BY message_id, collection;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, VectorCollection.style.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        var out: [String: MessageVectorCountBreakdown] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = String(cString: sqlite3_column_text(stmt, 0))
            let collectionRaw = String(cString: sqlite3_column_text(stmt, 1))
            let count = Int(sqlite3_column_int64(stmt, 2))
            var breakdown = out[messageId] ?? MessageVectorCountBreakdown()
            switch VectorCollection(rawValue: collectionRaw) {
            case .context:    breakdown.context = count
            case .attachment: breakdown.attachment = count
            case .entity:     breakdown.entity = count
            case .style, .none: break
            }
            out[messageId] = breakdown
        }
        return out
    }

    /// Single-row lookup; returns `nil` if no vector with that id exists.
    public func fetchVector(id: Int64) throws -> RawVec? {
        let sql = "SELECT vector_id, vector, layout_x, layout_y, layout_z FROM vectors WHERE vector_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rawVec(from: stmt)
    }
}
