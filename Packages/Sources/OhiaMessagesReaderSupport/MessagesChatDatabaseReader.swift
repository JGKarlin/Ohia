import Darwin
import Foundation
import OhiaMessagesReaderProtocol
import SQLite3

/// The only production type that opens Messages' database. It accepts only
/// normalized handles and returns value rows; it has no Contacts, network,
/// Keychain, or Ohia-storage dependency.
public struct MessagesChatDatabaseReader: Sendable {
    private let databaseURL: URL
    private let dateScaleCache: MessagesDateScaleCache

    public init(
        databaseURL: URL? = nil
    ) {
        self.databaseURL = databaseURL ?? Self.messagesDatabaseURL(
            sandboxHome: FileManager.default.homeDirectoryForCurrentUser,
            loginHome: Self.loginHomeDirectory()
        )
        self.dateScaleCache = MessagesDateScaleCache()
    }

    static func messagesDatabaseURL(
        sandboxHome: URL,
        loginHome: URL?
    ) -> URL {
        (loginHome ?? sandboxHome)
            .appendingPathComponent("Library/Messages/chat.db")
    }

    private static func loginHomeDirectory() -> URL? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4_096)
        let status = buffer.withUnsafeMutableBufferPointer {
            getpwuid_r(
                getuid(),
                &record,
                $0.baseAddress!,
                $0.count,
                &result
            )
        }
        guard status == 0,
              result != nil,
              let home = record.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }

    public func accessStatus() -> Bool {
        guard let database = openReadOnly() else { return false }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM message LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        return result == SQLITE_ROW || result == SQLITE_DONE
    }

    public func transcript(request: MessagesReaderRequest) -> MessagesReaderResponse {
        guard let database = openReadOnly() else { return .databaseUnavailable }
        defer { sqlite3_close(database) }
        return transcript(request: request, database: database)
    }

    func transcript(
        request: MessagesReaderRequest,
        database: OpaquePointer
    ) -> MessagesReaderResponse {
        let candidates = HandleCandidates(
            emails: Set(request.emailHandles.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }),
            phoneDigits: Set(request.phoneHandles.map(Self.digitsOnly).filter { !$0.isEmpty })
        )
        guard !candidates.isEmpty, request.limit > 0 else {
            return MessagesReaderResponse(status: .noMatchingChat)
        }

        do {
            let handleRowIDs = try matchedHandleRowIDs(
                database: database,
                candidates: candidates
            )
            guard !handleRowIDs.isEmpty else {
                return MessagesReaderResponse(status: .noMatchingChat)
            }
            let chatRowIDs = try matchedOneToOneChatRowIDs(
                database: database,
                handleRowIDs: handleRowIDs
            )
            guard !chatRowIDs.isEmpty else {
                return MessagesReaderResponse(status: .noMatchingChat)
            }

            let boundedLimit = min(request.limit, MessagesReaderRequest.maximumLimit)
            let rows = try messages(
                database: database,
                chatRowIDs: chatRowIDs,
                rowCap: max(boundedLimit * 4, MessagesReaderRequest.maximumLimit)
            )
            let nanosecondScale = try dateScaleCache.value {
                try Self.detectsNanosecondScale(database: database)
            }
            let lines = Self.transcriptLines(
                from: rows,
                nanosecondScale: nanosecondScale,
                cutoff: request.cutoff,
                limit: boundedLimit
            )
            guard !lines.isEmpty else {
                return MessagesReaderResponse(status: .noMatchingChat)
            }
            return MessagesReaderResponse(status: .found, lines: lines)
        } catch {
            return .databaseUnavailable
        }
    }

    private func openReadOnly() -> OpaquePointer? {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(database, 2_000)
        return database
    }

    struct HandleCandidates {
        let emails: Set<String>
        let phoneDigits: Set<String>

        var isEmpty: Bool {
            emails.isEmpty && phoneDigits.isEmpty
        }
    }

    static func digitsOnly(_ value: String) -> String {
        String(value.unicodeScalars.filter(CharacterSet.decimalDigits.contains))
    }

    static func phoneHandlesMatch(_ candidateDigits: String, _ handle: String) -> Bool {
        let handleDigits = digitsOnly(handle)
        guard candidateDigits.count >= 6, handleDigits.count >= 6 else { return false }
        let suffixLength = min(8, candidateDigits.count, handleDigits.count)
        return candidateDigits.suffix(suffixLength) == handleDigits.suffix(suffixLength)
    }

    private func matchedHandleRowIDs(
        database: OpaquePointer,
        candidates: HandleCandidates
    ) throws -> Set<Int64> {
        let statement = try Self.prepare(database, sql: "SELECT ROWID, id FROM handle;")
        defer { sqlite3_finalize(statement) }

        var matched: Set<Int64> = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let identifier = Self.columnText(statement, index: 1) {
                let rowID = sqlite3_column_int64(statement, 0)
                if identifier.contains("@"),
                   candidates.emails.contains(identifier.lowercased()) {
                    matched.insert(rowID)
                } else if candidates.phoneDigits.contains(where: {
                    Self.phoneHandlesMatch($0, identifier)
                }) {
                    matched.insert(rowID)
                }
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { throw MessagesDatabaseError.queryFailed }
        return matched
    }

    private func matchedOneToOneChatRowIDs(
        database: OpaquePointer,
        handleRowIDs: Set<Int64>
    ) throws -> Set<Int64> {
        let placeholders = Array(repeating: "?", count: handleRowIDs.count)
            .joined(separator: ",")
        let statement = try Self.prepare(database, sql: """
        SELECT DISTINCT chat.ROWID
        FROM chat
        JOIN chat_handle_join ON chat_handle_join.chat_id = chat.ROWID
        WHERE chat.style = 45
          AND chat_handle_join.handle_id IN (\(placeholders));
        """)
        defer { sqlite3_finalize(statement) }

        for (offset, handleRowID) in handleRowIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(offset + 1), handleRowID)
        }
        var chatRowIDs: Set<Int64> = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            chatRowIDs.insert(sqlite3_column_int64(statement, 0))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { throw MessagesDatabaseError.queryFailed }
        return chatRowIDs
    }

    struct RawMessageRow {
        let rawDate: Int64
        let text: String?
        let attributedBody: Data?
        let isFromMe: Bool
        let itemType: Int64
        let associatedMessageType: Int64
        let hasAttachments: Bool
    }

    private func messages(
        database: OpaquePointer,
        chatRowIDs: Set<Int64>,
        rowCap: Int
    ) throws -> [RawMessageRow] {
        let placeholders = Array(repeating: "?", count: chatRowIDs.count)
            .joined(separator: ",")
        let statement = try Self.prepare(database, sql: """
        SELECT message.date, message.text, message.attributedBody,
               message.is_from_me, message.item_type,
               message.associated_message_type, message.cache_has_attachments
        FROM message
        JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
        WHERE chat_message_join.chat_id IN (\(placeholders))
        ORDER BY message.date DESC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for chatRowID in chatRowIDs {
            sqlite3_bind_int64(statement, bindIndex, chatRowID)
            bindIndex += 1
        }
        sqlite3_bind_int64(statement, bindIndex, Int64(rowCap))

        var rows: [RawMessageRow] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let attributedBody: Data?
            if let bytes = sqlite3_column_blob(statement, 2) {
                attributedBody = Data(
                    bytes: bytes,
                    count: Int(sqlite3_column_bytes(statement, 2))
                )
            } else {
                attributedBody = nil
            }
            rows.append(RawMessageRow(
                rawDate: sqlite3_column_int64(statement, 0),
                text: Self.columnText(statement, index: 1),
                attributedBody: attributedBody,
                isFromMe: sqlite3_column_int64(statement, 3) != 0,
                itemType: sqlite3_column_int64(statement, 4),
                associatedMessageType: sqlite3_column_int64(statement, 5),
                hasAttachments: sqlite3_column_int64(statement, 6) != 0
            ))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { throw MessagesDatabaseError.queryFailed }
        return rows
    }

    static func transcriptLines(
        from rows: [RawMessageRow],
        nanosecondScale: Bool,
        cutoff: Date,
        limit: Int
    ) -> [MessagesReaderTranscriptLine] {
        rows.compactMap { row -> MessagesReaderTranscriptLine? in
            guard row.itemType == 0, row.associatedMessageType < 2_000 else {
                return nil
            }
            let date = Self.date(fromRaw: row.rawDate, nanosecondScale: nanosecondScale)
            guard date >= cutoff, let text = resolvedText(for: row) else { return nil }
            return MessagesReaderTranscriptLine(
                date: date,
                isFromMe: row.isFromMe,
                text: text
            )
        }
        .prefix(max(0, limit))
        .sorted { $0.date < $1.date }
    }

    static func resolvedText(for row: RawMessageRow) -> String? {
        if let text = row.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let attributedBody = row.attributedBody,
           let text = MessagesTypedStreamText.extractPlainText(from: attributedBody) {
            return text
        }
        return row.hasAttachments ? "[attachment]" : nil
    }

    static func detectsNanosecondScale(database: OpaquePointer) throws -> Bool {
        let statement = try prepare(database, sql: "SELECT MAX(date) FROM message;")
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw MessagesDatabaseError.queryFailed
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return true
        }
        return sqlite3_column_int64(statement, 0) > 1_000_000_000_000
    }

    static func date(fromRaw raw: Int64, nanosecondScale: Bool) -> Date {
        let seconds = nanosecondScale ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSince1970: seconds + 978_307_200)
    }

    private static func prepare(_ database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MessagesDatabaseError.queryFailed
        }
        return statement
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

private enum MessagesDatabaseError: Error {
    case queryFailed
}

private final class MessagesDateScaleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedValue: Bool?

    func value(compute: () throws -> Bool) rethrows -> Bool {
        try lock.withLock {
            if let cachedValue { return cachedValue }
            let detected = try compute()
            cachedValue = detected
            return detected
        }
    }
}
