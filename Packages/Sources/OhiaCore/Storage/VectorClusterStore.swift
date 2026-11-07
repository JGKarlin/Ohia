import Foundation
import SQLite3
import simd

// SQLite requires the destructor argument of `sqlite3_bind_text` to be either
// SQLITE_STATIC or SQLITE_TRANSIENT; the latter tells SQLite to make its own
// copy of the bytes. Neither macro is bridged to Swift, so we reconstruct
// SQLITE_TRANSIENT (== -1 cast to a function pointer) ourselves. Mirrors the
// pattern in `VectorFrameLayoutStore` / `VectorStore`.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One weighted member of an incoming cluster payload for `upsertClusters`.
public struct ClusterMemberUpsert: Sendable, Equatable {
    public let vectorId: Int64
    /// Normalized intra-cluster attachment in (0, 1].
    public let weight: Float
    public init(vectorId: Int64, weight: Float) {
        self.vectorId = vectorId
        self.weight = weight
    }
}

/// One incoming cluster payload for `upsertClusters`: a layout-space anchor
/// (medoid) plus its weighted member set.
public struct ClusterUpsert: Sendable {
    public let medoid: SIMD3<Float>
    public let members: [ClusterMemberUpsert]
    public init(medoid: SIMD3<Float>, members: [ClusterMemberUpsert]) {
        self.medoid = medoid
        self.members = members
    }
}

/// Bookkeeping row for one frame's clustering runs: the fingerprint of the
/// corpus the persisted clusters were computed over, when the last full refit
/// happened, and how many vectors have been folded in incrementally since.
public struct ClusterRunRecord: Sendable, Equatable {
    public let frameKey: FrameKey
    public let inputFingerprint: String
    public let fullRefitAt: Date
    public let incrementalAdds: Int
    public init(frameKey: FrameKey, inputFingerprint: String, fullRefitAt: Date, incrementalAdds: Int) {
        self.frameKey = frameKey
        self.inputFingerprint = inputFingerprint
        self.fullRefitAt = fullRefitAt
        self.incrementalAdds = incrementalAdds
    }
}

/// Per-frame clusters discovered over settled layout positions. Shares
/// the SQLite handle with its host `VectorStore` (see `VectorNeighborsStore`
/// and `VectorFrameLayoutStore` for the same pattern). Writes are atomic per
/// frame via `upsertClusters`, which matches incoming clusters to existing
/// rows by member-set Jaccard overlap so cluster ids (and user-visible
/// labels) survive re-clustering; reads are sorted by `member_count` desc so
/// the largest clusters render first in the billboard label pass.
public final class VectorClusterStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock: SQLiteConnectionLock

    /// Minimum member-set Jaccard overlap for an incoming cluster to inherit
    /// an existing cluster's identity (id + label).
    public static let matchJaccardThreshold = 0.25

    public convenience init(sharedDB: OpaquePointer) {
        self.init(sharedDB: sharedDB, lock: SQLiteConnectionLock())
    }

    public init(sharedDB: OpaquePointer, lock: SQLiteConnectionLock) {
        self.db = sharedDB
        self.lock = lock
    }

    /// Reconciles the frame's clusters with `clusters`, preserving cluster
    /// identity where membership overlaps. One transaction.
    ///
    /// Matching is greedy in descending Jaccard order (ties: larger
    /// intersection, then smaller existing cluster id, then earlier incoming
    /// position); a pair matches when Jaccard ≥ `matchJaccardThreshold`.
    /// Matched clusters keep their `cluster_id` and `label` and get their
    /// anchor, member count, detection time, and membership rows (with
    /// weights) replaced. Unmatched incoming clusters insert fresh rows with
    /// a NULL label; existing clusters with no match are deleted (cascade
    /// removes their membership rows).
    public func upsertClusters(frame: FrameKey, clusters: [ClusterUpsert]) throws {
        try lock.withLock {
        try exec("BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }

        // Existing clusters (including memberless ones) and their member sets.
        var existingMembers: [Int64: Set<Int64>] = [:]
        do {
            var stmt: OpaquePointer?
            try prepare("SELECT cluster_id FROM vector_clusters WHERE frame_key = ?;", stmt: &stmt)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                existingMembers[sqlite3_column_int64(stmt, 0)] = []
            }
        }
        do {
            var stmt: OpaquePointer?
            try prepare("""
            SELECT m.cluster_id, m.vector_id
            FROM vector_cluster_members m
            JOIN vector_clusters c ON c.cluster_id = m.cluster_id
            WHERE c.frame_key = ?;
            """, stmt: &stmt)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                existingMembers[sqlite3_column_int64(stmt, 0), default: []]
                    .insert(sqlite3_column_int64(stmt, 1))
            }
        }

        // Greedy identity matching. The candidate sort is a total order
        // (existing id and incoming index are unique per pair), so matching
        // is deterministic regardless of dictionary iteration order.
        struct MatchCandidate {
            let jaccard: Double
            let intersection: Int
            let existingId: Int64
            let incomingIndex: Int
        }
        let incomingSets: [Set<Int64>] = clusters.map { Set($0.members.map(\.vectorId)) }
        var candidates: [MatchCandidate] = []
        for (incomingIndex, incoming) in incomingSets.enumerated() where !incoming.isEmpty {
            for (existingId, existing) in existingMembers where !existing.isEmpty {
                let intersection = incoming.intersection(existing).count
                guard intersection > 0 else { continue }
                let union = incoming.count + existing.count - intersection
                let jaccard = Double(intersection) / Double(union)
                guard jaccard >= Self.matchJaccardThreshold else { continue }
                candidates.append(MatchCandidate(
                    jaccard: jaccard,
                    intersection: intersection,
                    existingId: existingId,
                    incomingIndex: incomingIndex
                ))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.jaccard != rhs.jaccard { return lhs.jaccard > rhs.jaccard }
            if lhs.intersection != rhs.intersection { return lhs.intersection > rhs.intersection }
            if lhs.existingId != rhs.existingId { return lhs.existingId < rhs.existingId }
            return lhs.incomingIndex < rhs.incomingIndex
        }
        var matchedExisting: Set<Int64> = []
        var matchForIncoming: [Int: Int64] = [:]
        for candidate in candidates {
            guard matchForIncoming[candidate.incomingIndex] == nil,
                  matchedExisting.contains(candidate.existingId) == false else { continue }
            matchForIncoming[candidate.incomingIndex] = candidate.existingId
            matchedExisting.insert(candidate.existingId)
        }

        var updateCluster: OpaquePointer?
        try prepare("""
        UPDATE vector_clusters
        SET centroid_x = ?, centroid_y = ?, centroid_z = ?, member_count = ?, detected_at = ?
        WHERE cluster_id = ?;
        """, stmt: &updateCluster)
        defer { sqlite3_finalize(updateCluster) }

        var deleteMembers: OpaquePointer?
        try prepare("DELETE FROM vector_cluster_members WHERE cluster_id = ?;", stmt: &deleteMembers)
        defer { sqlite3_finalize(deleteMembers) }

        var insertCluster: OpaquePointer?
        try prepare("""
        INSERT INTO vector_clusters (frame_key, centroid_x, centroid_y, centroid_z, member_count, detected_at, label)
        VALUES (?, ?, ?, ?, ?, ?, NULL);
        """, stmt: &insertCluster)
        defer { sqlite3_finalize(insertCluster) }

        var insertMember: OpaquePointer?
        try prepare("""
        INSERT OR REPLACE INTO vector_cluster_members (cluster_id, vector_id, weight)
        VALUES (?, ?, ?);
        """, stmt: &insertMember)
        defer { sqlite3_finalize(insertMember) }

        var deleteCluster: OpaquePointer?
        try prepare("DELETE FROM vector_clusters WHERE cluster_id = ?;", stmt: &deleteCluster)
        defer { sqlite3_finalize(deleteCluster) }

        // Existing clusters with no incoming match are dropped first so their
        // membership rows never coexist with the refreshed generation.
        for existingId in existingMembers.keys.sorted() where matchedExisting.contains(existingId) == false {
            sqlite3_bind_int64(deleteCluster, 1, existingId)
            guard sqlite3_step(deleteCluster) == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(deleteCluster)
        }

        let now = Date().timeIntervalSince1970
        for (incomingIndex, cluster) in clusters.enumerated() {
            let clusterId: Int64
            if let existingId = matchForIncoming[incomingIndex] {
                clusterId = existingId
                sqlite3_bind_double(updateCluster, 1, Double(cluster.medoid.x))
                sqlite3_bind_double(updateCluster, 2, Double(cluster.medoid.y))
                sqlite3_bind_double(updateCluster, 3, Double(cluster.medoid.z))
                sqlite3_bind_int64(updateCluster, 4, Int64(cluster.members.count))
                sqlite3_bind_double(updateCluster, 5, now)
                sqlite3_bind_int64(updateCluster, 6, existingId)
                guard sqlite3_step(updateCluster) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_reset(updateCluster)
                sqlite3_bind_int64(deleteMembers, 1, existingId)
                guard sqlite3_step(deleteMembers) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_reset(deleteMembers)
            } else {
                sqlite3_bind_text(insertCluster, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(insertCluster, 2, Double(cluster.medoid.x))
                sqlite3_bind_double(insertCluster, 3, Double(cluster.medoid.y))
                sqlite3_bind_double(insertCluster, 4, Double(cluster.medoid.z))
                sqlite3_bind_int64(insertCluster, 5, Int64(cluster.members.count))
                sqlite3_bind_double(insertCluster, 6, now)
                guard sqlite3_step(insertCluster) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_reset(insertCluster)
                clusterId = sqlite3_last_insert_rowid(db)
            }
            for member in cluster.members {
                sqlite3_bind_int64(insertMember, 1, clusterId)
                sqlite3_bind_int64(insertMember, 2, member.vectorId)
                sqlite3_bind_double(insertMember, 3, Double(member.weight))
                guard sqlite3_step(insertMember) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_reset(insertMember)
            }
        }
        try exec("COMMIT;")
        committed = true
        }
    }

    /// Inserts (or replaces) membership rows across clusters and refreshes
    /// cached member counts, in one transaction. Used by the incremental
    /// meaning-assignment path; the count refresh also reconciles counts
    /// after cascade deletions removed rows out-of-band.
    public func insertMembers(_ members: [(clusterId: Int64, vectorId: Int64, weight: Float)]) throws {
        try lock.withLock {
        try exec("BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }
        if members.isEmpty == false {
            var stmt: OpaquePointer?
            try prepare("""
            INSERT OR REPLACE INTO vector_cluster_members (cluster_id, vector_id, weight)
            VALUES (?, ?, ?);
            """, stmt: &stmt)
            defer { sqlite3_finalize(stmt) }
            for member in members {
                sqlite3_bind_int64(stmt, 1, member.clusterId)
                sqlite3_bind_int64(stmt, 2, member.vectorId)
                sqlite3_bind_double(stmt, 3, Double(member.weight))
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_reset(stmt)
            }
        }
        try refreshMemberCounts()
        try exec("COMMIT;")
        committed = true
        }
    }

    /// Rewrites stored cluster anchors (medoids) without touching membership
    /// or detection timestamps. One transaction.
    public func updateClusterAnchors(_ anchors: [(clusterId: Int64, medoid: SIMD3<Float>)]) throws {
        guard anchors.isEmpty == false else { return }
        try lock.withLock {
        try exec("BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }
        var stmt: OpaquePointer?
        try prepare("""
        UPDATE vector_clusters SET centroid_x = ?, centroid_y = ?, centroid_z = ?
        WHERE cluster_id = ?;
        """, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        for anchor in anchors {
            sqlite3_bind_double(stmt, 1, Double(anchor.medoid.x))
            sqlite3_bind_double(stmt, 2, Double(anchor.medoid.y))
            sqlite3_bind_double(stmt, 3, Double(anchor.medoid.z))
            sqlite3_bind_int64(stmt, 4, anchor.clusterId)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(stmt)
        }
        try exec("COMMIT;")
        committed = true
        }
    }

    // MARK: - Cluster runs

    public func clusterRun(frame: FrameKey) throws -> ClusterRunRecord? {
        try lock.withLock {
        var stmt: OpaquePointer?
        try prepare("""
        SELECT input_fingerprint, full_refit_at, incremental_adds
        FROM vector_cluster_runs WHERE frame_key = ?;
        """, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ClusterRunRecord(
            frameKey: frame,
            inputFingerprint: String(cString: sqlite3_column_text(stmt, 0)),
            fullRefitAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            incrementalAdds: Int(sqlite3_column_int64(stmt, 2))
        )
        }
    }

    public func recordClusterRun(_ record: ClusterRunRecord) throws {
        try lock.withLock {
        var stmt: OpaquePointer?
        try prepare("""
        INSERT OR REPLACE INTO vector_cluster_runs (frame_key, input_fingerprint, full_refit_at, incremental_adds)
        VALUES (?, ?, ?, ?);
        """, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, record.frameKey.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, record.inputFingerprint, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, record.fullRefitAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 4, Int64(record.incrementalAdds))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        }
    }

    public func deleteClusterRun(frame: FrameKey) throws {
        try lock.withLock {
        var stmt: OpaquePointer?
        try prepare("DELETE FROM vector_cluster_runs WHERE frame_key = ?;", stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        }
    }

    public func clusters(for frame: FrameKey) throws -> [ClusterRecord] {
        try lock.withLock {
        let sql = """
        SELECT cluster_id, frame_key, centroid_x, centroid_y, centroid_z, member_count, detected_at, label
        FROM vector_clusters WHERE frame_key = ? ORDER BY member_count DESC;
        """
        var stmt: OpaquePointer?
        try prepare(sql, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
        var out: [ClusterRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let label: String? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 7))
            out.append(ClusterRecord(
                id: sqlite3_column_int64(stmt, 0),
                frameKey: FrameKey(rawValue: String(cString: sqlite3_column_text(stmt, 1))),
                centroid: SIMD3<Float>(
                    Float(sqlite3_column_double(stmt, 2)),
                    Float(sqlite3_column_double(stmt, 3)),
                    Float(sqlite3_column_double(stmt, 4))
                ),
                memberCount: Int(sqlite3_column_int64(stmt, 5)),
                detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                label: label
            ))
        }
        return out
        }
    }

    public func vectorToCluster(frame: FrameKey) throws -> [Int64: Int64] {
        try lock.withLock {
        let sql = """
        SELECT m.vector_id, m.cluster_id
        FROM vector_cluster_members m
        JOIN vector_clusters c ON c.cluster_id = m.cluster_id
        WHERE c.frame_key = ?;
        """
        var stmt: OpaquePointer?
        try prepare(sql, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
        var out: [Int64: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[sqlite3_column_int64(stmt, 0)] = sqlite3_column_int64(stmt, 1)
        }
        return out
        }
    }

    /// Like `vectorToCluster(frame:)` but also carries each member's stored
    /// attachment weight. Legacy rows written before the weight column read
    /// back 1.0.
    public func vectorToClusterWeighted(frame: FrameKey) throws -> [Int64: (clusterId: Int64, weight: Float)] {
        try lock.withLock {
        let sql = """
        SELECT m.vector_id, m.cluster_id, m.weight
        FROM vector_cluster_members m
        JOIN vector_clusters c ON c.cluster_id = m.cluster_id
        WHERE c.frame_key = ?;
        """
        var stmt: OpaquePointer?
        try prepare(sql, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
        var out: [Int64: (clusterId: Int64, weight: Float)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[sqlite3_column_int64(stmt, 0)] = (
                clusterId: sqlite3_column_int64(stmt, 1),
                weight: Float(sqlite3_column_double(stmt, 2))
            )
        }
        return out
        }
    }

    public func setLabel(_ label: String, forCluster clusterId: Int64) throws {
        try lock.withLock {
        var stmt: OpaquePointer?
        try prepare("UPDATE vector_clusters SET label = ? WHERE cluster_id = ?;", stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, label, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, clusterId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        }
    }

    /// Frames containing at least one cluster member whose vector belongs to
    /// `messageId`. Capture this before removing memberships.
    public func framesContaining(messageId: String) throws -> Set<FrameKey> {
        try lock.withLock {
        let sql = """
        SELECT DISTINCT c.frame_key
        FROM vector_clusters c
        JOIN vector_cluster_members m ON c.cluster_id = m.cluster_id
        JOIN vectors v ON v.vector_id = m.vector_id
        WHERE v.message_id = ?;
        """
        var stmt: OpaquePointer?
        try prepare(sql, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)
        var frames: Set<FrameKey> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            frames.insert(FrameKey(rawValue: String(cString: sqlite3_column_text(stmt, 0))))
        }
        return frames
        }
    }

    /// Drop cluster membership rows for vectors belonging to `messageId`, then
    /// refresh cached member counts so subsequent reads see the reduced size.
    public func removeMembership(forMessageId messageId: String) throws {
        try lock.withLock {
        let sql = """
        DELETE FROM vector_cluster_members
        WHERE vector_id IN (SELECT vector_id FROM vectors WHERE message_id = ?);
        """
        var stmt: OpaquePointer?
        try prepare(sql, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        try refreshMemberCounts()
        }
    }

    /// Count cluster membership rows for vectors belonging to `messageId`.
    public func memberCount(forMessageId messageId: String) throws -> Int {
        try lock.withLock {
        let sql = """
        SELECT COUNT(*)
        FROM vector_cluster_members m
        JOIN vectors v ON v.vector_id = m.vector_id
        WHERE v.message_id = ?;
        """
        var stmt: OpaquePointer?
        try prepare(sql, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Peer message ids that share at least one cluster with `messageId` in
    /// the requested frame. Used by Composer to consume existing Meaning-lens
    /// cluster evidence without running clustering during draft intake.
    public func messagesSharingCluster(
        withMessageId messageId: String,
        frame: FrameKey,
        limit: Int
    ) throws -> Set<String> {
        guard limit > 0 else { return [] }
        return try lock.withLock {
        let sql = """
        SELECT DISTINCT peer.message_id
        FROM vector_cluster_members anchor_member
        JOIN vector_clusters c ON c.cluster_id = anchor_member.cluster_id
        JOIN vectors anchor ON anchor.vector_id = anchor_member.vector_id
        JOIN vector_cluster_members peer_member ON peer_member.cluster_id = anchor_member.cluster_id
        JOIN vectors peer ON peer.vector_id = peer_member.vector_id
        WHERE c.frame_key = ?
          AND anchor.message_id = ?
          AND peer.message_id != ?
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        try prepare(sql, stmt: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frame.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, messageId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, messageId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(limit))

        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
        }
    }

    private func refreshMemberCounts() throws {
        try exec("""
        UPDATE vector_clusters
        SET member_count = (
            SELECT COUNT(*)
            FROM vector_cluster_members
            WHERE vector_cluster_members.cluster_id = vector_clusters.cluster_id
        );
        """)
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
