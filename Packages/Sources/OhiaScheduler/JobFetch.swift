import Foundation
import SQLite3
import SwiftData
import OhiaCore

private let OHIA_JOBFETCH_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum JobFetch {
#if DEBUG
    @TaskLocal
    private static var sqliteJobFetchTestStoreURL: URL?

    @TaskLocal
    private static var forceSQLiteJobFetchInTests = false

    @MainActor
    static func withSQLiteJobFetchTestStore<T>(
        _ storeURL: URL,
        operation: () throws -> T
    ) rethrows -> T {
        try $sqliteJobFetchTestStoreURL.withValue(storeURL) {
            try $forceSQLiteJobFetchInTests.withValue(true) {
                try operation()
            }
        }
    }
#endif

    @MainActor
    public static func pending(context: ModelContext) throws -> [Job] {
        try jobs(for: .pending, context: context, sort: true)
    }

    @MainActor
    public static func running(context: ModelContext) throws -> [Job] {
        try jobs(for: .running, context: context, sort: true)
    }

    @MainActor
    public static func failed(context: ModelContext) throws -> [Job] {
        try jobs(for: .failed, context: context, sort: true)
    }

    @MainActor
    public static func completed(context: ModelContext) throws -> [Job] {
        try jobs(for: .completed, context: context, sort: true)
    }

    @MainActor
    public static func active(context: ModelContext) throws -> [Job] {
        try pending(context: context) + running(context: context)
    }

    @MainActor
    public static func jobs(
        type: JobType,
        statuses: [JobStatus],
        context: ModelContext,
        sort: Bool = false
    ) throws -> [Job] {
        guard statuses.isEmpty == false else { return [] }
        if let ids = try sqliteIDs(type: type, statuses: statuses, sort: sort) {
            return try fetchJobs(ids: ids, context: context)
        }
        let statusSet = Set(statuses)
        let sortBy = sort
            ? [SortDescriptor(\Job.priority), SortDescriptor(\Job.createdAt)]
            : []
        return try context.fetch(FetchDescriptor<Job>(sortBy: sortBy)).filter { job in
            job.type == type && statusSet.contains(job.status)
        }
    }

    @MainActor
    public static func activeTypes(context: ModelContext) throws -> Set<JobType> {
        if let types = try sqliteTypes(for: [.pending, .running]) {
            return types
        }
        return Set(try active(context: context).map(\.type))
    }

    /// Job types that can execute now. Running rows always count; pending rows
    /// respect their retry/defer timestamp. The SQLite path avoids materializing
    /// a potentially large ingestion queue for frequent resource-policy probes.
    @MainActor
    public static func runnableActiveTypes(
        now: Date,
        context: ModelContext
    ) throws -> Set<JobType> {
        if let types = try sqliteRunnableActiveTypes(now: now) {
            return types
        }
        return Set(try active(context: context).compactMap { job in
            if job.status == .running { return job.type }
            if let nextAttemptAt = job.nextAttemptAt, nextAttemptAt > now {
                return nil
            }
            return job.type
        })
    }

    @MainActor
    public static func activeJobExists(
        type: JobType,
        statuses: [JobStatus] = [.pending, .running],
        context: ModelContext
    ) throws -> Bool {
        guard statuses.isEmpty == false else { return false }
        if let exists = try sqliteJobExists(type: type, statuses: statuses) {
            return exists
        }
        let statusSet = Set(statuses)
        return try context.fetch(FetchDescriptor<Job>()).contains { job in
            job.type == type && statusSet.contains(job.status)
        }
    }

    @MainActor
    public static func unfinished(context: ModelContext) throws -> [Job] {
        try pending(context: context) + running(context: context) + failed(context: context)
    }

    @MainActor
    public static func unfinishedCountsByTypeAndStatus(context: ModelContext) throws -> [String: Int] {
        if let counts = try sqliteCounts(for: [.pending, .running, .failed]) {
            return counts
        }
        return try unfinished(context: context).reduce(into: [:]) { counts, job in
            counts["\(job.type.rawValue):\(job.status.rawValue)", default: 0] += 1
        }
    }

    @MainActor
    public static func hasPendingJob(
        type: JobType,
        maxPriority: Int? = nil,
        requiresMessageID: Bool = false,
        context: ModelContext
    ) throws -> Bool {
        if let exists = try sqlitePendingJobExists(
            type: type,
            maxPriority: maxPriority,
            requiresMessageID: requiresMessageID
        ) {
            return exists
        }
        return try pending(context: context).contains { job in
            guard job.type == type else { return false }
            if let maxPriority, job.priority > maxPriority { return false }
            if requiresMessageID, job.messageId == nil { return false }
            return true
        }
    }

    @MainActor
    public static func hasPendingLiveMessageJob(
        type: JobType,
        maxPriority: Int,
        context: ModelContext
    ) throws -> Bool {
        if let exists = try sqlitePendingLiveMessageJobExists(
            type: type,
            maxPriority: maxPriority
        ) {
            return exists
        }
        let pending = try pending(context: context).filter { job in
            job.type == type
                && job.messageId != nil
                && job.priority <= maxPriority
        }
        guard pending.isEmpty == false else { return false }
        for job in pending {
            guard let messageID = job.messageId else { continue }
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.id == messageID
                }
            )
            descriptor.fetchLimit = 1
            if try context.fetch(descriptor).first?.liveDetectedAt != nil {
                return true
            }
        }
        return false
    }

    @MainActor
    public static func pendingCount(context: ModelContext) throws -> Int {
        if let count = try sqliteCount(for: .pending) {
            return count
        }
        return try fallbackJobs(for: .pending, context: context, sort: false).count
    }

    @MainActor
    public static func claimablePendingJobs(
        maxPriority: Int,
        now: Date,
        excludedTypes: Set<JobType>,
        ownedTypes: Set<JobType>? = nil,
        limit: Int,
        context: ModelContext
    ) throws -> [Job] {
        guard limit > 0 else { return [] }
        if let ids = try sqliteClaimablePendingIDs(
            maxPriority: maxPriority,
            now: now,
            excludedTypes: excludedTypes,
            ownedTypes: ownedTypes,
            limit: limit
        ) {
            return try fetchJobs(ids: ids, context: context)
        }
        return Array(
            try pending(context: context)
                .filter { job in
                    guard job.priority <= maxPriority else { return false }
                    guard !excludedTypes.contains(job.type) else { return false }
                    if let ownedTypes, !ownedTypes.contains(job.type) { return false }
                    if let nextAt = job.nextAttemptAt, nextAt > now { return false }
                    return true
                }
                .prefix(limit)
        )
    }

    @MainActor
    public static func claimablePendingJobs(
        type: JobType,
        now: Date,
        limit: Int,
        context: ModelContext
    ) throws -> [Job] {
        guard limit > 0 else { return [] }
        if let ids = try sqliteClaimablePendingIDs(
            type: type,
            now: now,
            limit: limit
        ) {
            return try fetchJobs(ids: ids, context: context)
        }
        return Array(
            try pending(context: context)
                .filter { job in
                    guard job.type == type else { return false }
                    if let nextAt = job.nextAttemptAt, nextAt > now { return false }
                    return true
                }
                .prefix(limit)
        )
    }

    /// When the most recent job of `types` reached one of the terminal
    /// `statuses` (`completedAt` is stamped for both completion and final
    /// failure), at or before `notAfter`; a stamp from a clock that has since
    /// stepped backward is ignored. One aggregate query on the SQLite path, so
    /// the job history is never materialized for a scheduling decision.
    @MainActor
    public static func latestCompletedAt(
        types: Set<JobType>,
        statuses: [JobStatus],
        notAfter: Date,
        context: ModelContext
    ) throws -> Date? {
        guard types.isEmpty == false, statuses.isEmpty == false else { return nil }
        if let latest = try sqliteLatestCompletedAt(
            types: types,
            statuses: statuses,
            notAfter: notAfter
        ) {
            return latest
        }
        let statusSet = Set(statuses)
        return try context.fetch(FetchDescriptor<Job>())
            .filter { types.contains($0.type) && statusSet.contains($0.status) }
            .compactMap(\.completedAt)
            .filter { $0 <= notAfter }
            .max()
    }

    /// When the oldest job of `type` in `statuses` was created. One aggregate
    /// query on the SQLite path.
    @MainActor
    public static func earliestCreatedAt(
        type: JobType,
        statuses: [JobStatus],
        context: ModelContext
    ) throws -> Date? {
        guard statuses.isEmpty == false else { return nil }
        if let earliest = try sqliteEarliestCreatedAt(type: type, statuses: statuses) {
            return earliest
        }
        return try jobs(type: type, statuses: statuses, context: context)
            .map(\.createdAt)
            .min()
    }

    @MainActor
    static func completedOrFailed(olderThan date: Date, context: ModelContext) throws -> [Job] {
        if let ids = try sqliteIDsForCompletedOrFailed(olderThan: date) {
            return try fetchJobs(ids: ids, context: context)
        }
        return try context.fetch(FetchDescriptor<Job>()).filter { job in
            guard let completedAt = job.completedAt, completedAt < date else { return false }
            return job.status == .completed || job.status == .failed
        }
    }

    @MainActor
    private static func jobs(for status: JobStatus, context: ModelContext, sort: Bool) throws -> [Job] {
        if let ids = try sqliteIDs(for: status, sort: sort) {
            return try fetchJobs(ids: ids, context: context)
        }
        return try fallbackJobs(for: status, context: context, sort: sort)
    }

    @MainActor
    private static func fallbackJobs(for status: JobStatus, context: ModelContext, sort: Bool) throws -> [Job] {
        let sortBy = sort
            ? [SortDescriptor(\Job.priority), SortDescriptor(\Job.createdAt)]
            : []
        return try context.fetch(FetchDescriptor<Job>(sortBy: sortBy)).filter { $0.status == status }
    }

    @MainActor
    private static func fetchJobs(ids: [UUID], context: ModelContext) throws -> [Job] {
        guard !ids.isEmpty else { return [] }

        var jobs: [Job] = []
        jobs.reserveCapacity(ids.count)
        for id in ids {
            var descriptor = FetchDescriptor<Job>(
                predicate: #Predicate<Job> { job in
                    job.id == id
                }
            )
            descriptor.fetchLimit = 1
            if let job = try context.fetch(descriptor).first {
                jobs.append(job)
            }
        }
        return jobs
    }

    private static func sqliteIDs(for status: JobStatus, sort: Bool) throws -> [UUID]? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let orderSQL = sort ? "ORDER BY ZPRIORITY ASC, ZCREATEDAT ASC, Z_PK ASC" : ""
        return try selectJobIDs(
            db: db,
            sql: """
            SELECT ZID
            FROM ZJOB
            WHERE ZSTATUS = ?
            \(orderSQL);
            """,
            strings: [status.rawValue]
        )
    }

    private static func sqliteIDs(
        type: JobType,
        statuses: [JobStatus],
        sort: Bool
    ) throws -> [UUID]? {
        guard shouldUseSQLiteJobFetch,
              statuses.isEmpty == false,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
        let orderSQL = sort ? "ORDER BY ZPRIORITY ASC, ZCREATEDAT ASC, Z_PK ASC" : ""
        return try selectJobIDs(
            db: db,
            sql: """
            SELECT ZID
            FROM ZJOB
            WHERE ZTYPE = ?
              AND ZSTATUS IN (\(placeholders))
            \(orderSQL);
            """,
            strings: [type.rawValue] + statuses.map(\.rawValue)
        )
    }

    private static func sqliteIDsForCompletedOrFailed(olderThan date: Date) throws -> [UUID]? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        return try selectJobIDs(
            db: db,
            sql: """
            SELECT ZID
            FROM ZJOB
            WHERE ZSTATUS IN (?, ?)
              AND ZCOMPLETEDAT IS NOT NULL
              AND ZCOMPLETEDAT < ?
            ORDER BY ZCOMPLETEDAT ASC, Z_PK ASC;
            """,
            strings: [JobStatus.completed.rawValue, JobStatus.failed.rawValue],
            doubles: [date.timeIntervalSinceReferenceDate]
        )
    }

    /// Nil when the SQLite path is unavailable; `.some(nil)` when no row matches.
    private static func sqliteLatestCompletedAt(
        types: Set<JobType>,
        statuses: [JobStatus],
        notAfter: Date
    ) throws -> Date?? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let typeValues = types.map(\.rawValue).sorted()
        let statusValues = statuses.map(\.rawValue).sorted()
        let typePlaceholders = Array(repeating: "?", count: typeValues.count).joined(separator: ", ")
        let statusPlaceholders = Array(repeating: "?", count: statusValues.count).joined(separator: ", ")
        return try selectDate(
            db: db,
            sql: """
            SELECT MAX(ZCOMPLETEDAT)
            FROM ZJOB
            WHERE ZTYPE IN (\(typePlaceholders))
              AND ZSTATUS IN (\(statusPlaceholders))
              AND ZCOMPLETEDAT <= ?;
            """,
            strings: typeValues + statusValues,
            doubles: [notAfter.timeIntervalSinceReferenceDate]
        )
    }

    /// Nil when the SQLite path is unavailable; `.some(nil)` when no row matches.
    private static func sqliteEarliestCreatedAt(
        type: JobType,
        statuses: [JobStatus]
    ) throws -> Date?? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
        return try selectDate(
            db: db,
            sql: """
            SELECT MIN(ZCREATEDAT)
            FROM ZJOB
            WHERE ZTYPE = ?
              AND ZSTATUS IN (\(placeholders));
            """,
            strings: [type.rawValue] + statuses.map(\.rawValue)
        )
    }

    private static func selectDate(
        db: OpaquePointer,
        sql: String,
        strings: [String],
        doubles: [Double] = []
    ) throws -> Date? {
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        for (index, value) in strings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        }
        for (index, value) in doubles.enumerated() {
            sqlite3_bind_double(statement, Int32(strings.count + index + 1), value)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteFailure(db: db, message: "Failed to read job date bound")
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0))
    }

    private static func sqliteCount(for status: JobStatus) throws -> Int? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let statement = try prepare(
            """
            SELECT COUNT(*)
            FROM ZJOB
            WHERE ZSTATUS = ?;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, status.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteFailure(db: db, message: "Failed to count \(status.rawValue) jobs")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func sqliteCounts(for statuses: [JobStatus]) throws -> [String: Int]? {
        guard shouldUseSQLiteJobFetch,
              statuses.isEmpty == false,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
        let statement = try prepare(
            """
            SELECT ZTYPE, ZSTATUS, COUNT(*)
            FROM ZJOB
            WHERE ZSTATUS IN (\(placeholders))
            GROUP BY ZTYPE, ZSTATUS;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        for (index, status) in statuses.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), status.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        }

        var counts: [String: Int] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                guard let typePointer = sqlite3_column_text(statement, 0),
                      let statusPointer = sqlite3_column_text(statement, 1) else {
                    continue
                }
                let type = String(cString: typePointer)
                let status = String(cString: statusPointer)
                counts["\(type):\(status)"] = Int(sqlite3_column_int64(statement, 2))
            } else if code == SQLITE_DONE {
                break
            } else {
                throw SQLiteFailure(db: db, message: "Failed to count unfinished jobs")
            }
        }
        return counts
    }

    private static func sqlitePendingJobExists(
        type: JobType,
        maxPriority: Int?,
        requiresMessageID: Bool
    ) throws -> Bool? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let prioritySQL = maxPriority == nil ? "" : "AND ZPRIORITY <= ?"
        let messageSQL = requiresMessageID ? "AND ZMESSAGEID IS NOT NULL" : ""
        let statement = try prepare(
            """
            SELECT 1
            FROM ZJOB
            WHERE ZTYPE = ?
              AND ZSTATUS = ?
              \(prioritySQL)
              \(messageSQL)
            LIMIT 1;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, type.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, JobStatus.pending.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        if let maxPriority {
            sqlite3_bind_int(statement, 3, Int32(maxPriority))
        }

        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw SQLiteFailure(db: db, message: "Failed to test pending \(type.rawValue) jobs")
    }

    private static func sqliteJobExists(
        type: JobType,
        statuses: [JobStatus]
    ) throws -> Bool? {
        guard shouldUseSQLiteJobFetch,
              statuses.isEmpty == false,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
        let statement = try prepare(
            """
            SELECT 1
            FROM ZJOB
            WHERE ZTYPE = ?
              AND ZSTATUS IN (\(placeholders))
            LIMIT 1;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, type.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        for (index, status) in statuses.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 2), status.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        }

        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw SQLiteFailure(db: db, message: "Failed to test active \(type.rawValue) jobs")
    }

    private static func sqlitePendingLiveMessageJobExists(
        type: JobType,
        maxPriority: Int
    ) throws -> Bool? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let statement = try prepare(
            """
            SELECT 1
            FROM ZJOB J
            INNER JOIN ZMESSAGE M ON M.ZID = J.ZMESSAGEID
            WHERE J.ZTYPE = ?
              AND J.ZSTATUS = ?
              AND J.ZPRIORITY <= ?
              AND J.ZMESSAGEID IS NOT NULL
              AND M.ZLIVEDETECTEDAT IS NOT NULL
            LIMIT 1;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, type.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, JobStatus.pending.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 3, Int32(maxPriority))

        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw SQLiteFailure(db: db, message: "Failed to test pending live \(type.rawValue) jobs")
    }

    private static func sqliteTypes(for statuses: [JobStatus]) throws -> Set<JobType>? {
        guard shouldUseSQLiteJobFetch,
              statuses.isEmpty == false,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
        let statement = try prepare(
            """
            SELECT DISTINCT ZTYPE
            FROM ZJOB
            WHERE ZSTATUS IN (\(placeholders));
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        for (index, status) in statuses.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), status.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        }

        var types = Set<JobType>()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                guard let cString = sqlite3_column_text(statement, 0),
                      let type = JobType(rawValue: String(cString: cString)) else {
                    continue
                }
                types.insert(type)
            } else if code == SQLITE_DONE {
                break
            } else {
                throw SQLiteFailure(db: db, message: "Failed to read active job types")
            }
        }
        return types
    }

    private static func sqliteRunnableActiveTypes(now: Date) throws -> Set<JobType>? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let statement = try prepare(
            """
            SELECT DISTINCT ZTYPE
            FROM ZJOB
            WHERE ZSTATUS = ?
               OR (ZSTATUS = ? AND (ZNEXTATTEMPTAT IS NULL OR ZNEXTATTEMPTAT <= ?));
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, JobStatus.running.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, JobStatus.pending.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 3, now.timeIntervalSinceReferenceDate)

        var types = Set<JobType>()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                guard let cString = sqlite3_column_text(statement, 0),
                      let type = JobType(rawValue: String(cString: cString)) else {
                    continue
                }
                types.insert(type)
            } else if code == SQLITE_DONE {
                break
            } else {
                throw SQLiteFailure(db: db, message: "Failed to read runnable active job types")
            }
        }
        return types
    }

    private static func sqliteClaimablePendingIDs(
        maxPriority: Int,
        now: Date,
        excludedTypes: Set<JobType>,
        ownedTypes: Set<JobType>?,
        limit: Int
    ) throws -> [UUID]? {
        if let ownedTypes, ownedTypes.isEmpty {
            return []
        }
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let excluded = excludedTypes.map(\.rawValue).sorted()
        let owned = ownedTypes?.map(\.rawValue).sorted() ?? []
        let excludedSQL = excluded.isEmpty
            ? ""
            : "AND ZTYPE NOT IN (\(Array(repeating: "?", count: excluded.count).joined(separator: ", ")))"
        let ownedSQL = ownedTypes == nil
            ? ""
            : "AND ZTYPE IN (\(Array(repeating: "?", count: owned.count).joined(separator: ", ")))"

        let statement = try prepare(
            """
            SELECT ZID
            FROM ZJOB
            WHERE ZSTATUS = ?
              AND ZPRIORITY <= ?
              AND (ZNEXTATTEMPTAT IS NULL OR ZNEXTATTEMPTAT <= ?)
              \(excludedSQL)
              \(ownedSQL)
            ORDER BY ZPRIORITY ASC, ZCREATEDAT ASC, Z_PK ASC
            LIMIT ?;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        sqlite3_bind_text(statement, bindIndex, JobStatus.pending.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(maxPriority))
        bindIndex += 1
        sqlite3_bind_double(statement, bindIndex, now.timeIntervalSinceReferenceDate)
        bindIndex += 1
        for type in excluded {
            sqlite3_bind_text(statement, bindIndex, type, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
            bindIndex += 1
        }
        for type in owned {
            sqlite3_bind_text(statement, bindIndex, type, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
            bindIndex += 1
        }
        sqlite3_bind_int64(statement, bindIndex, Int64(max(1, limit)))

        return try readJobIDs(statement: statement, db: db)
    }

    private static func sqliteClaimablePendingIDs(
        type: JobType,
        now: Date,
        limit: Int
    ) throws -> [UUID]? {
        guard shouldUseSQLiteJobFetch,
              let db = try openDefaultStoreReadOnly() else {
            return nil
        }
        defer { sqlite3_close(db) }

        let statement = try prepare(
            """
            SELECT ZID
            FROM ZJOB
            WHERE ZTYPE = ?
              AND ZSTATUS = ?
              AND (ZNEXTATTEMPTAT IS NULL OR ZNEXTATTEMPTAT <= ?)
            ORDER BY ZPRIORITY ASC, ZCREATEDAT ASC, Z_PK ASC
            LIMIT ?;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, type.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, JobStatus.pending.rawValue, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 3, now.timeIntervalSinceReferenceDate)
        sqlite3_bind_int64(statement, 4, Int64(max(1, limit)))

        return try readJobIDs(statement: statement, db: db)
    }

    private static var shouldUseSQLiteJobFetch: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["OHIA_DISABLE_SQLITE_JOB_FETCH"] == "1" {
            return false
        }
#if DEBUG
        if forceSQLiteJobFetchInTests {
            return true
        }
#endif
        if environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.processName == "xctest" ||
            ProcessInfo.processInfo.arguments.contains(where: { $0.contains(".xctest") }) {
            return false
        }
        return true
    }

    private static func openDefaultStoreReadOnly() throws -> OpaquePointer? {
#if DEBUG
        let storeURL = sqliteJobFetchTestStoreURL ?? MessageStoreHotPath.defaultStoreURL()
#else
        let storeURL = MessageStoreHotPath.defaultStoreURL()
#endif
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        var db: OpaquePointer?
        let code = sqlite3_open_v2(
            storeURL.path,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open Ohia.store"
            if let db { sqlite3_close(db) }
            throw SQLiteFailure(code: code, message: message)
        }
        sqlite3_busy_timeout(db, 10_000)
        return db
    }

    private static func selectJobIDs(
        db: OpaquePointer,
        sql: String,
        strings: [String],
        doubles: [Double] = []
    ) throws -> [UUID] {
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        for (index, value) in strings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, OHIA_JOBFETCH_SQLITE_TRANSIENT)
        }
        for (index, value) in doubles.enumerated() {
            sqlite3_bind_double(statement, Int32(strings.count + index + 1), value)
        }

        return try readJobIDs(statement: statement, db: db)
    }

    private static func readJobIDs(statement: OpaquePointer, db: OpaquePointer) throws -> [UUID] {
        var ids: [UUID] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                guard let data = blobData(statement, column: 0),
                      let id = uuid(from: data) else {
                    continue
                }
                ids.append(id)
            } else if code == SQLITE_DONE {
                break
            } else {
                throw SQLiteFailure(db: db, message: "Failed to read job IDs")
            }
        }
        return ids
    }

    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteFailure(db: db, message: "Failed to prepare job query")
        }
        return statement
    }

    private static func blobData(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let blob = sqlite3_column_blob(statement, column) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: blob, count: count)
    }

    private static func uuid(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        return data.withUnsafeBytes { rawBuffer -> UUID? in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return UUID(uuid: (
                base[0], base[1], base[2], base[3],
                base[4], base[5], base[6], base[7],
                base[8], base[9], base[10], base[11],
                base[12], base[13], base[14], base[15]
            ))
        }
    }
}

private struct SQLiteFailure: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    init(code: Int32 = SQLITE_ERROR, message: String) {
        self.code = code
        self.message = message
    }

    init(db: OpaquePointer, message: String) {
        self.code = sqlite3_errcode(db)
        self.message = "\(message): \(String(cString: sqlite3_errmsg(db)))"
    }

    var description: String {
        "SQLite error \(code): \(message)"
    }
}
