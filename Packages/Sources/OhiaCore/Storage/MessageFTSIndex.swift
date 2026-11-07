import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR_FTS = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// FTS5 virtual table over message text for sparse retrieval.
public final class MessageFTSIndex: @unchecked Sendable {

    private let db: OpaquePointer
    private let lock: SQLiteConnectionLock

    public convenience init(sharedDB: OpaquePointer) throws {
        try self.init(sharedDB: sharedDB, lock: SQLiteConnectionLock())
    }

    public init(sharedDB: OpaquePointer, lock: SQLiteConnectionLock) throws {
        self.db = sharedDB
        self.lock = lock
        try createSchema()
    }

    private func createSchema() throws {
        let ddl = """
        CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
            message_id UNINDEXED,
            subject,
            body,
            sender_email,
            tokenize = 'trigram'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS message_attachment_fts USING fts5(
            message_id UNINDEXED,
            filename,
            body,
            tokenize = 'trigram'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS message_attachment_evidence_fts USING fts5(
            message_id UNINDEXED,
            attachment_id UNINDEXED,
            filename,
            modality UNINDEXED,
            body,
            tokenize = 'trigram'
        );
        CREATE TABLE IF NOT EXISTS message_filter_metadata (
            message_id TEXT PRIMARY KEY,
            account_id TEXT,
            received_at REAL,
            sender_email TEXT NOT NULL,
            has_attachment INTEGER NOT NULL DEFAULT 0,
            is_active INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS message_semantic_visibility (
            message_id TEXT PRIMARY KEY,
            is_active INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_message_filter_metadata_account ON message_filter_metadata(account_id);
        CREATE INDEX IF NOT EXISTS idx_message_filter_metadata_received_at ON message_filter_metadata(received_at);
        CREATE INDEX IF NOT EXISTS idx_message_filter_metadata_sender ON message_filter_metadata(sender_email);
        CREATE INDEX IF NOT EXISTS idx_message_filter_metadata_attachment ON message_filter_metadata(has_attachment);
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, ddl, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw VectorStoreError.prepareFailed("FTS5 create failed: \(message)")
        }
        try addColumnIfMissing(
            table: "message_filter_metadata",
            column: "is_active",
            declaration: "INTEGER NOT NULL DEFAULT 1"
        )
        try exec("""
        INSERT OR IGNORE INTO message_semantic_visibility (message_id, is_active)
        SELECT message_id, is_active
        FROM message_filter_metadata;
        """)
        try migrateAttachmentSidecarRowsToEvidenceTable()
        try migrateLegacyInlineAttachmentTextRows()
    }

    public func upsert(
        messageId: String,
        subject: String,
        body: String,
        senderEmail: String,
        accountId: String? = nil,
        receivedAt: TimeInterval? = nil,
        hasAttachment: Bool = false,
        attachments: [FTSAttachmentDocument] = []
    ) throws {
        try lock.withLock {
        try remove(messageId: messageId)

        try insertMessageFTSRowLocked(
            messageId: messageId,
            subject: subject,
            body: body,
            senderEmail: senderEmail
        )

        let metadataSQL = """
        INSERT INTO message_filter_metadata
            (message_id, account_id, received_at, sender_email, has_attachment, is_active)
        VALUES (?, ?, ?, ?, ?, COALESCE(
            (SELECT is_active FROM message_semantic_visibility WHERE message_id = ?),
            1
        ));
        """
        var metadataStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, metadataSQL, -1, &metadataStmt, nil) == SQLITE_OK, let stmt = metadataStmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        if let accountId {
            sqlite3_bind_text(stmt, 2, accountId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let receivedAt {
            sqlite3_bind_double(stmt, 3, receivedAt)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, senderEmail, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        sqlite3_bind_int64(stmt, 5, hasAttachment ? 1 : 0)
        sqlite3_bind_text(stmt, 6, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        try insertAttachmentRowsLocked(messageId: messageId, attachments: attachments)
        }
    }

    public func remove(messageId: String) throws {
        try lock.withLock {
        try delete(messageId: messageId, table: "message_fts")
        try delete(messageId: messageId, table: "message_attachment_fts")
        try delete(messageId: messageId, table: "message_attachment_evidence_fts")
        try delete(messageId: messageId, table: "message_filter_metadata")
        }
    }

    /// Permanent account removal also forgets the visibility tombstone. The
    /// ordinary Trash path keeps that tombstone to reject late embeddings.
    public func forgetMessage(messageId: String) throws {
        try lock.withLock {
            try remove(messageId: messageId)
            try delete(messageId: messageId, table: "message_semantic_visibility")
        }
    }

    /// Toggle semantic visibility without deleting FTS rows. Ordinary Trash
    /// uses this reversible sidecar bit so Restore does not need to reparse or
    /// reindex the message and attachment text.
    public func setMessageActive(messageId: String, isActive: Bool) throws {
        try lock.withLock {
            try exec("BEGIN IMMEDIATE;")
            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }

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
            sqlite3_bind_text(visibilityStmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            sqlite3_bind_int64(visibilityStmt, 2, isActive ? 1 : 0)
            guard sqlite3_step(visibilityStmt) == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

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
            sqlite3_bind_text(metadataStmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            sqlite3_bind_int64(metadataStmt, 2, isActive ? 1 : 0)
            guard sqlite3_step(metadataStmt) == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            try exec("COMMIT;")
            committed = true
        }
    }

    /// Clears the full-text sidecar tables without closing or unlinking the
    /// shared SQLite database used by `VectorStore`.
    public func removeAllData() throws {
        try lock.withLock {
            try exec("DELETE FROM message_fts;")
            try exec("DELETE FROM message_attachment_fts;")
            try exec("DELETE FROM message_attachment_evidence_fts;")
            try exec("DELETE FROM message_filter_metadata;")
        }
    }

    public func search(queryText: String, limit: Int) throws -> [String] {
        try searchImpl(queryText: queryText, filter: nil, limit: limit)
    }

    public func search(queryText: String, filter: FilterSpec, limit: Int) throws -> [String] {
        try searchImpl(queryText: queryText, filter: filter, limit: limit)
    }

    private func searchImpl(queryText: String, filter: FilterSpec?, limit: Int) throws -> [String] {
        try lock.withLock {
        guard limit > 0 else { return [] }
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let allowedMessageIds = filter?.allowedMessageIds, allowedMessageIds.isEmpty {
            return []
        }

        let matchExpression = Self.matchExpression(for: trimmed)
        let messageRows = try rankedMessagesLocked(matchExpression: matchExpression, filter: filter, limit: limit)
        let attachmentRows = try rankedAttachmentMatchesLocked(matchExpression: matchExpression, filter: filter, limit: limit)
        var rows: [String] = []
        var seen = Set<String>()
        for row in messageRows where seen.insert(row.messageId).inserted {
            rows.append(row.messageId)
            if rows.count == limit { return rows }
        }
        for row in attachmentRows where seen.insert(row.messageId).inserted {
            rows.append(row.messageId)
            if rows.count == limit { return rows }
        }
        return rows
        }
    }

    // MARK: - Literal (exact-biased) search

    /// Ranked literal matches for a caller-built FTS5 MATCH expression, with
    /// per-column membership (subject / body / sender) annotated on each row.
    /// Powers the Constellation Search tab's exact-biased finder: the caller
    /// (OhiaML `LexicalSearchEngine`) owns the query semantics (phrase vs
    /// AND-of-terms) and passes the assembled expression here. The supplied
    /// `filter` is applied through `message_filter_metadata`, so the result
    /// honours the active Constellation top-bar filter scope.
    public func literalMatches(
        matchExpression: String,
        filter: FilterSpec?,
        limit: Int
    ) throws -> [FTSLiteralMatch] {
        try lock.withLock {
            guard limit > 0 else { return [] }
            let expr = matchExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { return [] }
            if let allowed = filter?.allowedMessageIds, allowed.isEmpty { return [] }

            let ranked = try rankedMessagesLocked(matchExpression: expr, filter: filter, limit: limit)
            guard !ranked.isEmpty else { return [] }
            let ids = ranked.map(\.messageId)
            let subjectSet = try columnMembershipLocked(column: "subject", baseExpression: expr, messageIds: ids)
            let bodySet = try columnMembershipLocked(column: "body", baseExpression: expr, messageIds: ids)
            let senderSet = try columnMembershipLocked(column: "sender_email", baseExpression: expr, messageIds: ids)

            return ranked.map { row in
                var columns: FTSColumnSet = []
                if subjectSet.contains(row.messageId) { columns.insert(.subject) }
                if bodySet.contains(row.messageId) { columns.insert(.body) }
                if senderSet.contains(row.messageId) { columns.insert(.sender) }
                return FTSLiteralMatch(
                    messageId: row.messageId,
                    subject: row.subject,
                    senderEmail: row.sender,
                    receivedAt: row.received,
                    columns: columns
                )
            }
        }
    }

    /// Count of distinct messages matching a caller-built FTS5 MATCH
    /// expression within the filter scope. Used for the unbounded headline
    /// count and the per-term / per-field breakdown, independent of the
    /// (capped) `literalMatches` navigable set.
    public func literalMatchCount(
        matchExpression: String,
        filter: FilterSpec?
    ) throws -> Int {
        try lock.withLock {
            let expr = matchExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { return 0 }
            if let allowed = filter?.allowedMessageIds, allowed.isEmpty { return 0 }
            return try matchCountLocked(matchExpression: expr, filter: filter)
        }
    }

    public func literalAttachmentMatches(
        matchExpression: String,
        filter: FilterSpec?,
        limit: Int
    ) throws -> [FTSAttachmentMatch] {
        try lock.withLock {
            guard limit > 0 else { return [] }
            let expr = matchExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { return [] }
            if let allowed = filter?.allowedMessageIds, allowed.isEmpty { return [] }
            return try rankedAttachmentMatchesLocked(matchExpression: expr, filter: filter, limit: limit)
        }
    }

    public func literalAttachmentMatchCount(
        matchExpression: String,
        filter: FilterSpec?
    ) throws -> Int {
        try lock.withLock {
            let expr = matchExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { return 0 }
            if let allowed = filter?.allowedMessageIds, allowed.isEmpty { return 0 }
            return try attachmentMatchCountLocked(matchExpression: expr, filter: filter)
        }
    }

    public func literalCombinedMatchCount(
        matchExpression: String,
        filter: FilterSpec?
    ) throws -> Int {
        try lock.withLock {
            let expr = matchExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { return 0 }
            if let allowed = filter?.allowedMessageIds, allowed.isEmpty { return 0 }
            return try combinedMatchCountLocked(matchExpression: expr, filter: filter)
        }
    }

    /// Subject/sender/date sidecar rows for already-scoped message ids. Used by
    /// dense-neighbor search to make semantic hits navigable without asking
    /// the app view layer to re-query storage.
    public func metadata(forMessageIds messageIds: [String]) throws -> [String: FTSMessageMetadata] {
        try lock.withLock {
            let uniqueIds = Array(Set(messageIds))
            guard !uniqueIds.isEmpty else { return [:] }

            let placeholders = Array(repeating: "?", count: uniqueIds.count).joined(separator: ",")
            let sql = """
            SELECT m.message_id, COALESCE(message_fts.subject, ''), m.sender_email, m.received_at
            FROM message_filter_metadata m
            LEFT JOIN message_fts ON message_fts.message_id = m.message_id
            WHERE m.is_active = 1
              AND m.message_id IN (\(placeholders));
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            for (offset, messageId) in uniqueIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(offset + 1), messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            }

            var out: [String: FTSMessageMetadata] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let messageId = String(cString: sqlite3_column_text(stmt, 0))
                let subject = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let sender = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let received: TimeInterval? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(stmt, 3)
                out[messageId] = FTSMessageMetadata(
                    messageId: messageId,
                    subject: subject,
                    senderEmail: sender,
                    receivedAt: received
                )
            }
            return out
        }
    }

    // The `*Locked` helpers assume the caller already holds `lock`.

    private func rankedMessagesLocked(
        matchExpression: String,
        filter: FilterSpec?,
        limit: Int
    ) throws -> [(messageId: String, subject: String, sender: String, received: TimeInterval?)] {
        let metadata = metadataFilterClauses(filter)
        var clauses = ["message_fts MATCH ?"]
        clauses.append(contentsOf: metadata.clauses)
        // Always join metadata — sender_email + received_at come from it.
        let sql = """
        SELECT message_fts.message_id, message_fts.subject, m.sender_email, m.received_at
        FROM message_fts
        JOIN message_filter_metadata m ON m.message_id = message_fts.message_id
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY bm25(message_fts, 0.0, 5.0, 1.0, 0.5)
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        sqlite3_bind_text(stmt, index, matchExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        index += 1
        try bind(metadata.bindings, to: stmt, startingAt: &index)
        sqlite3_bind_int64(stmt, index, Int64(limit))

        var rows: [(messageId: String, subject: String, sender: String, received: TimeInterval?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = String(cString: sqlite3_column_text(stmt, 0))
            let subject = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let sender = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let received: TimeInterval? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 3)
            rows.append((messageId, subject, sender, received))
        }
        return rows
    }

    private func rankedAttachmentMatchesLocked(
        matchExpression: String,
        filter: FilterSpec?,
        limit: Int
    ) throws -> [FTSAttachmentMatch] {
        let metadata = metadataFilterClauses(
            filter,
            messageIdColumn: "message_attachment_evidence_fts.message_id"
        )
        var clauses = ["message_attachment_evidence_fts MATCH ?"]
        clauses.append(contentsOf: metadata.clauses)
        let sql = """
        SELECT message_attachment_evidence_fts.rowid,
               message_attachment_evidence_fts.message_id,
               COALESCE(message_fts.subject, ''),
               m.sender_email,
               m.received_at,
               message_attachment_evidence_fts.attachment_id,
               message_attachment_evidence_fts.filename,
               message_attachment_evidence_fts.modality,
               message_attachment_evidence_fts.body
        FROM message_attachment_evidence_fts
        JOIN message_filter_metadata m ON m.message_id = message_attachment_evidence_fts.message_id
        LEFT JOIN message_fts ON message_fts.message_id = message_attachment_evidence_fts.message_id
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY bm25(message_attachment_evidence_fts, 0.8, 0.0, 5.0, 0.0, 4.0)
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        sqlite3_bind_text(stmt, index, matchExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        index += 1
        try bind(metadata.bindings, to: stmt, startingAt: &index)
        sqlite3_bind_int64(stmt, index, Int64(limit))

        struct AttachmentRow {
            let rowId: Int64
            let messageId: String
            let subject: String
            let sender: String
            let received: TimeInterval?
            let attachmentId: String?
            let filename: String
            let modality: String
            let body: String
        }

        var rawRows: [AttachmentRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let messageId = String(cString: sqlite3_column_text(stmt, 1))
            let subject = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let sender = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let received: TimeInterval? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 4)
            let attachmentId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let filename = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let modality = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let body = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
            rawRows.append(AttachmentRow(
                rowId: rowId,
                messageId: messageId,
                subject: subject,
                sender: sender,
                received: received,
                attachmentId: attachmentId,
                filename: filename,
                modality: modality,
                body: body
            ))
        }

        let filenameMatches = try attachmentFilenameMembershipLocked(
            baseExpression: matchExpression,
            rowIds: rawRows.map(\.rowId)
        )
        let bodyMatches = try attachmentBodyMembershipLocked(
            baseExpression: matchExpression,
            rowIds: rawRows.map(\.rowId)
        )
        return rawRows.map { row in
            let matchedFilename = filenameMatches.contains(row.rowId)
            let matchedBody = bodyMatches.contains(row.rowId)
            return FTSAttachmentMatch(
                messageId: row.messageId,
                subject: row.subject,
                senderEmail: row.sender,
                receivedAt: row.received,
                attachmentId: row.attachmentId,
                filename: row.filename,
                modality: row.modality,
                snippet: Self.snippet(from: row.body),
                matchedFilename: matchedFilename,
                matchedBody: matchedBody
            )
        }
    }

    private func columnMembershipLocked(
        column: String,
        baseExpression: String,
        messageIds: [String]
    ) throws -> Set<String> {
        guard !messageIds.isEmpty else { return [] }
        let scopedExpression = "{\(column)} : (\(baseExpression))"
        let placeholders = Array(repeating: "?", count: messageIds.count).joined(separator: ",")
        let sql = """
        SELECT message_fts.message_id
        FROM message_fts
        WHERE message_fts MATCH ? AND message_fts.message_id IN (\(placeholders));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, scopedExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        var index: Int32 = 2
        for messageId in messageIds {
            sqlite3_bind_text(stmt, index, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            index += 1
        }

        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    private func attachmentFilenameMembershipLocked(
        baseExpression: String,
        rowIds: [Int64]
    ) throws -> Set<Int64> {
        guard !rowIds.isEmpty else { return [] }
        let scopedExpression = "{filename} : (\(baseExpression))"
        let placeholders = Array(repeating: "?", count: rowIds.count).joined(separator: ",")
        let sql = """
        SELECT message_attachment_evidence_fts.rowid
        FROM message_attachment_evidence_fts
        WHERE message_attachment_evidence_fts MATCH ?
          AND message_attachment_evidence_fts.rowid IN (\(placeholders));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, scopedExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        var index: Int32 = 2
        for rowId in rowIds {
            sqlite3_bind_int64(stmt, index, rowId)
            index += 1
        }

        var out = Set<Int64>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(sqlite3_column_int64(stmt, 0))
        }
        return out
    }

    private func attachmentBodyMembershipLocked(
        baseExpression: String,
        rowIds: [Int64]
    ) throws -> Set<Int64> {
        guard !rowIds.isEmpty else { return [] }
        let scopedExpression = "{body} : (\(baseExpression))"
        let placeholders = Array(repeating: "?", count: rowIds.count).joined(separator: ",")
        let sql = """
        SELECT message_attachment_evidence_fts.rowid
        FROM message_attachment_evidence_fts
        WHERE message_attachment_evidence_fts MATCH ?
          AND message_attachment_evidence_fts.rowid IN (\(placeholders));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, scopedExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        var index: Int32 = 2
        for rowId in rowIds {
            sqlite3_bind_int64(stmt, index, rowId)
            index += 1
        }

        var out = Set<Int64>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(sqlite3_column_int64(stmt, 0))
        }
        return out
    }

    private func matchCountLocked(matchExpression: String, filter: FilterSpec?) throws -> Int {
        let metadata = metadataFilterClauses(filter)
        let join = metadata.requiresMetadata
            ? " JOIN message_filter_metadata m ON m.message_id = message_fts.message_id"
            : ""
        var clauses = ["message_fts MATCH ?"]
        clauses.append(contentsOf: metadata.clauses)
        // One FTS row per message (upsert is delete+insert), so COUNT(*) of
        // matching rows is the distinct-message count.
        let sql = """
        SELECT COUNT(*)
        FROM message_fts\(join)
        WHERE \(clauses.joined(separator: " AND "));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        sqlite3_bind_text(stmt, index, matchExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        index += 1
        try bind(metadata.bindings, to: stmt, startingAt: &index)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func attachmentMatchCountLocked(matchExpression: String, filter: FilterSpec?) throws -> Int {
        let metadata = metadataFilterClauses(
            filter,
            messageIdColumn: "message_attachment_evidence_fts.message_id"
        )
        let join = metadata.requiresMetadata
            ? " JOIN message_filter_metadata m ON m.message_id = message_attachment_evidence_fts.message_id"
            : ""
        var clauses = ["message_attachment_evidence_fts MATCH ?"]
        clauses.append(contentsOf: metadata.clauses)
        let sql = """
        SELECT COUNT(DISTINCT message_attachment_evidence_fts.message_id)
        FROM message_attachment_evidence_fts\(join)
        WHERE \(clauses.joined(separator: " AND "));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        sqlite3_bind_text(stmt, index, matchExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        index += 1
        try bind(metadata.bindings, to: stmt, startingAt: &index)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func combinedMatchCountLocked(matchExpression: String, filter: FilterSpec?) throws -> Int {
        let messageMetadata = metadataFilterClauses(filter)
        let attachmentMetadata = metadataFilterClauses(
            filter,
            messageIdColumn: "message_attachment_evidence_fts.message_id"
        )
        let messageJoin = messageMetadata.requiresMetadata
            ? " JOIN message_filter_metadata m ON m.message_id = message_fts.message_id"
            : ""
        let attachmentJoin = attachmentMetadata.requiresMetadata
            ? " JOIN message_filter_metadata m ON m.message_id = message_attachment_evidence_fts.message_id"
            : ""
        var messageClauses = ["message_fts MATCH ?"]
        messageClauses.append(contentsOf: messageMetadata.clauses)
        var attachmentClauses = ["message_attachment_evidence_fts MATCH ?"]
        attachmentClauses.append(contentsOf: attachmentMetadata.clauses)
        let sql = """
        SELECT COUNT(*)
        FROM (
            SELECT message_fts.message_id AS message_id
            FROM message_fts\(messageJoin)
            WHERE \(messageClauses.joined(separator: " AND "))
            UNION
            SELECT message_attachment_evidence_fts.message_id AS message_id
            FROM message_attachment_evidence_fts\(attachmentJoin)
            WHERE \(attachmentClauses.joined(separator: " AND "))
        );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        sqlite3_bind_text(stmt, index, matchExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        index += 1
        try bind(messageMetadata.bindings, to: stmt, startingAt: &index)
        sqlite3_bind_text(stmt, index, matchExpression, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        index += 1
        try bind(attachmentMetadata.bindings, to: stmt, startingAt: &index)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Shared filter-clause builder for the literal-search SQL. `requiresMetadata`
    /// is true when any clause references the joined `message_filter_metadata`
    /// row (the `allowedMessageIds` clause references the FTS table directly and
    /// does not force the join).
    private func metadataFilterClauses(
        _ filter: FilterSpec?,
        messageIdColumn: String = "message_fts.message_id"
    ) -> (clauses: [String], bindings: [SQLBindable], requiresMetadata: Bool) {
        var clauses = ["m.is_active = 1"]
        var bindings: [SQLBindable] = []
        guard let filter else { return (clauses, bindings, true) }
        if !filter.accountIds.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.accountIds.count).joined(separator: ",")
            clauses.append("m.account_id IN (\(placeholders))")
            bindings.append(contentsOf: filter.accountIds.map { .text($0.uuidString) })
        }
        if let range = filter.dateRange {
            clauses.append("m.received_at >= ?")
            clauses.append("m.received_at <= ?")
            bindings.append(.real(range.lowerBound.timeIntervalSince1970))
            bindings.append(.real(range.upperBound.timeIntervalSince1970))
        }
        if !filter.senderEmails.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.senderEmails.count).joined(separator: ",")
            clauses.append("m.sender_email IN (\(placeholders))")
            bindings.append(contentsOf: filter.senderEmails.map { .text($0) })
        }
        if let hasAttachment = filter.hasAttachment {
            clauses.append("m.has_attachment = ?")
            bindings.append(.integer(hasAttachment ? 1 : 0))
        }
        let requiresMetadata = true
        if let allowed = filter.allowedMessageIds {
            if allowed.isEmpty {
                // Empty allowed scope ⇒ no message can match. Emit an
                // always-false clause rather than an invalid `IN ()`, so every
                // caller (including the `*Locked` helpers) is safe even without
                // its own empty-scope guard.
                clauses.append("0")
            } else {
                let placeholders = Array(repeating: "?", count: allowed.count).joined(separator: ",")
                clauses.append("\(messageIdColumn) IN (\(placeholders))")
                bindings.append(contentsOf: allowed.map { .text($0) })
            }
        }
        return (clauses, bindings, requiresMetadata)
    }

    private func insertAttachmentRowsLocked(
        messageId: String,
        attachments: [FTSAttachmentDocument]
    ) throws {
        guard !attachments.isEmpty else { return }
        let legacySQL = """
        INSERT INTO message_attachment_fts (message_id, filename, body)
        VALUES (?, ?, ?);
        """
        let evidenceSQL = """
        INSERT INTO message_attachment_evidence_fts (message_id, attachment_id, filename, modality, body)
        VALUES (?, ?, ?, ?, ?);
        """
        for attachment in attachments {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, legacySQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            sqlite3_bind_text(stmt, 2, attachment.filename, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            sqlite3_bind_text(stmt, 3, attachment.body, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_finalize(stmt)

            var evidenceStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, evidenceSQL, -1, &evidenceStmt, nil) == SQLITE_OK, let evidenceStmt else {
                throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(evidenceStmt) }

            sqlite3_bind_text(evidenceStmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            if let attachmentId = attachment.attachmentId {
                sqlite3_bind_text(evidenceStmt, 2, attachmentId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            } else {
                sqlite3_bind_null(evidenceStmt, 2)
            }
            sqlite3_bind_text(evidenceStmt, 3, attachment.filename, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            sqlite3_bind_text(evidenceStmt, 4, attachment.modality, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            sqlite3_bind_text(evidenceStmt, 5, attachment.body, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)

            guard sqlite3_step(evidenceStmt) == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func insertMessageFTSRowLocked(
        messageId: String,
        subject: String,
        body: String,
        senderEmail: String
    ) throws {
        let sql = """
        INSERT INTO message_fts (message_id, subject, body, sender_email)
        VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        sqlite3_bind_text(stmt, 2, subject, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        sqlite3_bind_text(stmt, 3, body, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        sqlite3_bind_text(stmt, 4, senderEmail, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func migrateAttachmentSidecarRowsToEvidenceTable() throws {
        let sql = """
        SELECT message_id, filename, body
        FROM message_attachment_fts;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        var rows: [(messageId: String, filename: String, body: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((
                messageId: String(cString: sqlite3_column_text(stmt, 0)),
                filename: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                body: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            ))
        }
        sqlite3_finalize(stmt)

        for row in rows {
            guard try attachmentEvidenceRowCountLocked(
                messageId: row.messageId,
                filename: row.filename
            ) == 0 else {
                continue
            }
            try insertAttachmentEvidenceRowLocked(
                messageId: row.messageId,
                attachment: FTSAttachmentDocument(
                    filename: row.filename,
                    modality: "legacy-attachment",
                    body: row.body
                )
            )
        }
    }

    private func insertAttachmentEvidenceRowLocked(
        messageId: String,
        attachment: FTSAttachmentDocument
    ) throws {
        let sql = """
        INSERT INTO message_attachment_evidence_fts (message_id, attachment_id, filename, modality, body)
        VALUES (?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        if let attachmentId = attachment.attachmentId {
            sqlite3_bind_text(stmt, 2, attachmentId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, attachment.filename, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        sqlite3_bind_text(stmt, 4, attachment.modality, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        sqlite3_bind_text(stmt, 5, attachment.body, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func attachmentEvidenceRowCountLocked(
        messageId: String,
        filename: String
    ) throws -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM message_attachment_evidence_fts
        WHERE message_id = ? AND filename = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        sqlite3_bind_text(stmt, 2, filename, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func migrateLegacyInlineAttachmentTextRows() throws {
        let sql = """
        SELECT message_id, subject, body, sender_email
        FROM message_fts
        WHERE body LIKE '%ATTACHMENT:%';
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        var rows: [(messageId: String, subject: String, body: String, senderEmail: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((
                messageId: String(cString: sqlite3_column_text(stmt, 0)),
                subject: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                body: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                senderEmail: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            ))
        }
        sqlite3_finalize(stmt)

        for row in rows {
            guard let split = Self.splitLegacyInlineAttachmentBody(row.body) else { continue }
            if try attachmentRowCountLocked(messageId: row.messageId) == 0 {
                try insertAttachmentRowsLocked(messageId: row.messageId, attachments: split.attachments)
            }
            try delete(messageId: row.messageId, table: "message_fts")
            try insertMessageFTSRowLocked(
                messageId: row.messageId,
                subject: row.subject,
                body: split.body,
                senderEmail: row.senderEmail
            )
        }
    }

    private func attachmentRowCountLocked(messageId: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM message_attachment_fts WHERE message_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func splitLegacyInlineAttachmentBody(
        _ body: String
    ) -> (body: String, attachments: [FTSAttachmentDocument])? {
        let marker = "\n\nATTACHMENT: "
        let attachmentPrefix = "ATTACHMENT: "
        let bodyText: String
        let attachmentBlob: String
        if body.hasPrefix(attachmentPrefix) {
            bodyText = ""
            attachmentBlob = body
        } else if let markerRange = body.range(of: marker) {
            bodyText = String(body[..<markerRange.lowerBound])
            attachmentBlob = attachmentPrefix + String(body[markerRange.upperBound...])
        } else {
            return nil
        }

        let attachments = attachmentBlob
            .components(separatedBy: marker)
            .compactMap { rawPart -> FTSAttachmentDocument? in
                let part = rawPart.hasPrefix(attachmentPrefix)
                    ? String(rawPart.dropFirst(attachmentPrefix.count))
                    : rawPart
                guard let lineBreak = part.firstIndex(of: "\n") else { return nil }
                let filename = part[..<lineBreak]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let text = part[part.index(after: lineBreak)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return FTSAttachmentDocument(
                    filename: filename.isEmpty ? "attachment" : filename,
                    modality: "legacy-attachment",
                    body: text
                )
            }
        guard !attachments.isEmpty else { return nil }
        return (
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments
        )
    }

    private static func matchExpression(for queryText: String) -> String {
        let terms = queryTerms(from: queryText)
        guard !terms.isEmpty else {
            return quoted(queryText)
        }

        var expressions: [String] = []
        if terms.count > 1 {
            for index in terms.indices.dropLast() {
                expressions.append(quoted("\(terms[index]) \(terms[terms.index(after: index)])"))
            }
        }
        expressions.append(contentsOf: terms.map(quoted))

        var seen = Set<String>()
        let uniqueExpressions = expressions.filter { seen.insert($0).inserted }
        return uniqueExpressions.joined(separator: " OR ")
    }

    private static func queryTerms(from queryText: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        let stopwords: Set<String> = [
            "about", "after", "again", "also", "and", "any", "are", "ask", "can", "could",
            "did", "does", "email", "emails", "for", "from", "had", "has", "have", "how",
            "into", "mail", "message", "messages", "not", "our", "please", "should", "that",
            "the", "their", "there", "these", "this", "those", "was", "were", "what", "when",
            "where", "which", "who", "why", "with", "would", "you", "your"
        ]
        let rawTerms = queryText
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let meaningful = rawTerms.filter { term in
            guard term.count >= 3 else { return false }
            guard !stopwords.contains(term) else { return false }
            return seen.insert(term).inserted
        }
        if !meaningful.isEmpty {
            return Array(meaningful.prefix(12))
        }

        return Array(rawTerms.filter { $0.count >= 2 }.prefix(12))
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func snippet(from body: String, limit: Int = 220) -> String {
        let cleaned = body
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bind(
        _ values: [SQLBindable],
        to stmt: OpaquePointer,
        startingAt index: inout Int32
    ) throws {
        for value in values {
            switch value {
            case .text(let text):
                sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
            case .integer(let integer):
                sqlite3_bind_int64(stmt, index, integer)
            case .real(let double):
                sqlite3_bind_double(stmt, index, double)
            case .null:
                sqlite3_bind_null(stmt, index)
            }
            index += 1
        }
    }

    private func delete(messageId: String, table: String) throws {
        let sql = "DELETE FROM \(table) WHERE message_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT_DESTRUCTOR_FTS)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func addColumnIfMissing(
        table: String,
        column: String,
        declaration: String
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: rawName).caseInsensitiveCompare(column) == .orderedSame {
                exists = true
                break
            }
        }
        guard !exists else { return }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration);")
    }
}

/// Which FTS columns a literal query matched within a single message.
public struct FTSColumnSet: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let subject = FTSColumnSet(rawValue: 1 << 0)
    public static let body    = FTSColumnSet(rawValue: 1 << 1)
    public static let sender  = FTSColumnSet(rawValue: 1 << 2)
}

/// One literal (exact-biased) FTS hit: the message, its subject, its sender +
/// date (from the filter-metadata sidecar), and which columns the query
/// matched in.
public struct FTSLiteralMatch: Sendable, Equatable {
    public let messageId: String
    public let subject: String
    public let senderEmail: String
    public let receivedAt: TimeInterval?
    public let columns: FTSColumnSet

    public init(messageId: String, subject: String = "", senderEmail: String, receivedAt: TimeInterval?, columns: FTSColumnSet) {
        self.messageId = messageId
        self.subject = subject
        self.senderEmail = senderEmail
        self.receivedAt = receivedAt
        self.columns = columns
    }
}

public struct FTSAttachmentDocument: Sendable, Equatable {
    public let attachmentId: String?
    public let filename: String
    public let modality: String
    public let body: String

    public init(
        attachmentId: String? = nil,
        filename: String,
        modality: String = "attachment",
        body: String
    ) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.modality = modality
        self.body = body
    }
}

public struct FTSAttachmentMatch: Sendable, Equatable {
    public let messageId: String
    public let subject: String
    public let senderEmail: String
    public let receivedAt: TimeInterval?
    public let attachmentId: String?
    public let filename: String
    public let modality: String
    public let snippet: String
    public let matchedFilename: Bool
    public let matchedBody: Bool

    public init(
        messageId: String,
        subject: String = "",
        senderEmail: String,
        receivedAt: TimeInterval?,
        attachmentId: String? = nil,
        filename: String,
        modality: String = "attachment",
        snippet: String = "",
        matchedFilename: Bool = false,
        matchedBody: Bool = true
    ) {
        self.messageId = messageId
        self.subject = subject
        self.senderEmail = senderEmail
        self.receivedAt = receivedAt
        self.attachmentId = attachmentId
        self.filename = filename
        self.modality = modality
        self.snippet = snippet
        self.matchedFilename = matchedFilename
        self.matchedBody = matchedBody
    }

    public var provenanceLabel: String {
        if matchedFilename && !matchedBody {
            return "attachment filename"
        }
        switch modality {
        case "visualSummary":
            return "visual summary"
        case "attachmentSummary":
            return "attachment summary"
        case "labels":
            return "Vision labels"
        case "objects":
            return "Vision objects"
        case "ocr":
            return "attachment OCR"
        case "extractedText":
            return "attachment text"
        case "captureMetadata":
            return "capture metadata"
        case "legacy-attachment":
            return "attachment text"
        default:
            return "attachment"
        }
    }
}

/// Subject/sender/date metadata cached beside the FTS row.
public struct FTSMessageMetadata: Sendable, Equatable {
    public let messageId: String
    public let subject: String
    public let senderEmail: String
    public let receivedAt: TimeInterval?

    public init(messageId: String, subject: String = "", senderEmail: String, receivedAt: TimeInterval?) {
        self.messageId = messageId
        self.subject = subject
        self.senderEmail = senderEmail
        self.receivedAt = receivedAt
    }
}
