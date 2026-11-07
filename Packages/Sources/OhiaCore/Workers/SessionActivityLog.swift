import Foundation
import OSLog
import SQLite3

public struct SessionActivityEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case started, finished, failed, cancelled, ended, state, retryScheduled, blocked
    }

    public let id: UUID
    public let operationID: UUID
    public let timestamp: Date
    public let operation: String
    public let phase: Phase
    public let subject: String?
    public let accountID: UUID?
    public let accountName: String?
    public let detail: String?
    public let processID: Int32

    public init(operation: String, phase: Phase, subject: String? = nil,
                accountID: UUID? = nil, accountName: String? = nil, detail: String? = nil,
                operationID: UUID = UUID(), timestamp: Date = Date(),
                processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.id = UUID()
        self.operationID = operationID
        self.timestamp = timestamp
        self.operation = operation
        self.phase = phase
        self.subject = subject
        self.accountID = accountID
        self.accountName = accountName
        self.detail = detail
        self.processID = processID
    }

    public func ending(_ phase: Phase, detail: String? = nil) -> Self {
        Self(operation: operation, phase: phase, subject: subject, accountID: accountID,
             accountName: accountName, detail: detail, operationID: operationID, processID: processID)
    }
}

public struct SessionActivityRecord: Identifiable, Sendable {
    public let sequence: Int64
    public let event: SessionActivityEvent
    public var id: UUID { event.id }
}

public struct SessionActivityState: Sendable {
    public private(set) var active: [UUID: SessionActivityEvent] = [:]
    private var stoppedProcesses: Set<Int32> = []

    public init() {}

    /// Returns explicit interruptions to add to the history. Late writes from
    /// a stopped worker remain historical events, never current work.
    public mutating func consume(_ event: SessionActivityEvent) -> [SessionActivityEvent] {
        switch event.phase {
        case .started:
            if stoppedProcesses.contains(event.processID) {
                return [event.ending(.cancelled, detail: "Worker stopped before reporting an outcome")]
            }
            active[event.operationID] = event
        case .finished, .failed, .cancelled, .ended, .retryScheduled, .blocked:
            active.removeValue(forKey: event.operationID)
        case .state:
            if event.operation == "Worker stopped" {
                stoppedProcesses.insert(event.processID)
                let interrupted = active.values.filter { $0.processID == event.processID }
                for item in interrupted { active.removeValue(forKey: item.operationID) }
                return interrupted.map { $0.ending(.cancelled, detail: "Worker stopped before reporting an outcome") }
            }
        }
        return []
    }

    public func details(operation: String, accountID: UUID?, accountNames: [UUID: String]) -> String? {
        let targets = active.values.filter {
            $0.operation == operation && (accountID == nil || $0.accountID == accountID)
        }.compactMap { event -> String? in
            let account = event.accountName ?? event.accountID.flatMap { accountNames[$0] }
            guard event.subject != nil || account != nil else { return nil }
            return [event.subject.map { $0.isEmpty ? "No subject" : $0 }, account]
                .compactMap { $0 }.joined(separator: " · ")
        }
        let distinct = Set(targets).sorted()
        return distinct.isEmpty ? nil : distinct.joined(separator: "\n")
    }
}

/// A launch-scoped journal transports events from both workers without a lossy
/// snapshot ring. The app replaces the session on launch; old workers cannot
/// append into the new session. No mail processing depends on logging success.
/// Configuration is lock-protected; background writes are serialized per process.
public final class SessionActivityLog: @unchecked Sendable {
    public static let shared = SessionActivityLog()
    private static let logger = Logger(subsystem: "org.jgkarlin.Ohia", category: "activity-log")
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "org.jgkarlin.Ohia.activity-log", qos: .utility)
    private var directoryURL: URL?
    private var sessionID: String?
    private var lastStates: [String: SessionActivityEvent] = [:]

    public init(directoryURL: URL? = nil) { self.directoryURL = directoryURL }

    public static func operationTitle(_ raw: String) -> String {
        switch raw {
        case "summarize": return "Processing messages"
        case "embed": return "Embedding"
        case "generateDraft": return "Drafting"
        case "needsAttention": return "Attention"
        default:
            return raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
        }
    }

    public func startSession(directoryURL: URL? = nil) throws {
        if let directoryURL { lock.withLock { self.directoryURL = directoryURL } }
        let url = try location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString
        try database { db in
            try execute(db, "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS session (id TEXT NOT NULL); CREATE TABLE IF NOT EXISTS activity (sequence INTEGER PRIMARY KEY AUTOINCREMENT, sessionID TEXT NOT NULL, event BLOB NOT NULL);")
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try execute(db, "DELETE FROM activity; DELETE FROM session;")
                try statement(db, "INSERT INTO session VALUES (?)") { stmt in
                    bind(id, to: 1, in: stmt)
                    try stepDone(stmt, db: db)
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
        lock.withLock { sessionID = id; lastStates = [:] }
    }

    public func attachToSession(directoryURL: URL? = nil) throws {
        if let directoryURL { lock.withLock { self.directoryURL = directoryURL } }
        let id = try database { db in
            try statement(db, "SELECT id FROM session LIMIT 1") { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else {
                    throw LogError(message: "No activity-log session is available")
                }
                return String(cString: value)
            }
        }
        lock.withLock { sessionID = id }
    }

    public func record(_ event: SessionActivityEvent) {
        guard let id = lock.withLock({ sessionID }) else { return }
        writer.async { [self] in
            do { try append(event, sessionID: id) }
            catch { Self.logger.error("Activity log write failed: \(String(reflecting: type(of: error)), privacy: .public)") }
        }
    }

    public func recordState(_ event: SessionActivityEvent, channel: String) {
        let changed = lock.withLock {
            let previous = lastStates[channel]
            guard previous?.phase != event.phase || previous?.operation != event.operation || previous?.accountID != event.accountID
                || previous?.detail != event.detail else { return false }
            lastStates[channel] = event
            return true
        }
        if changed { record(event) }
    }

    public func append(_ event: SessionActivityEvent) throws {
        guard let id = lock.withLock({ sessionID }) else { return }
        try append(event, sessionID: id)
    }

    private func append(_ event: SessionActivityEvent, sessionID: String) throws {
        let data = try JSONEncoder().encode(event)
        try database { db in
            try statement(db, "INSERT INTO activity(sessionID,event) SELECT ?,? WHERE EXISTS(SELECT 1 FROM session WHERE id=?)") { stmt in
                bind(sessionID, to: 1, in: stmt)
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(stmt, 2, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                bind(sessionID, to: 3, in: stmt)
                try stepDone(stmt, db: db)
            }
        }
    }

    public func read(after sequence: Int64, limit: Int = 1000) throws -> [SessionActivityRecord] {
        guard let id = lock.withLock({ sessionID }) else { return [] }
        return try database { db in
            try statement(db, "SELECT sequence,event FROM activity WHERE sessionID=? AND sequence>? ORDER BY sequence LIMIT ?") { stmt in
                bind(id, to: 1, in: stmt)
                sqlite3_bind_int64(stmt, 2, sequence)
                sqlite3_bind_int64(stmt, 3, Int64(max(1, limit)))
                var result: [SessionActivityRecord] = []
                while true {
                    let step = sqlite3_step(stmt)
                    if step == SQLITE_DONE { return result }
                    guard step == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 1) else { throw failure(db) }
                    let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
                    result.append(SessionActivityRecord(sequence: sqlite3_column_int64(stmt, 0), event: try JSONDecoder().decode(SessionActivityEvent.self, from: data)))
                }
            }
        }
    }

    private func location() throws -> URL {
        guard let directory = lock.withLock({ directoryURL }) else {
            throw LogError(message: "Activity logging has not started")
        }
        return directory.appendingPathComponent("session-activity.sqlite")
    }

    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(try location().path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw LogError(message: "Unable to open the activity log (SQLite \(result))")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }

    private func statement<T>(_ db: OpaquePointer, _ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure(db) }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func bind(_ text: String, to index: Int32, in stmt: OpaquePointer) {
        _ = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }

    private func stepDone(_ stmt: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure(db) }
    }

    private func failure(_ db: OpaquePointer) -> LogError { LogError(message: String(cString: sqlite3_errmsg(db))) }
    private struct LogError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
