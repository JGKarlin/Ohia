import Foundation
import SQLite3

private let OHIA_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum MessageStoreWorkKind: Sendable {
    case embeddingPending

    fileprivate var whereSQL: String {
        switch self {
        case .embeddingPending:
            return "ZEMBEDDINGSTATUS IN (?, ?, ?)"
        }
    }

    fileprivate var bindValues: [String] {
        switch self {
        case .embeddingPending:
            return [
                ProcessingStatus.pending.rawValue,
                ProcessingStatus.processing.rawValue,
                ProcessingStatus.failed.rawValue
            ]
        }
    }
}

public struct MessageStoreActionabilitySnapshot: Sendable {
    public let totalMessages: Int
    public let hasEmbeddingPending: Bool
    public let hasSummaryPending: Bool
    public let hasBodySummaryPending: Bool
    public let hasDraftPending: Bool
    public let hasReplySourcePreparationPending: Bool
    /// Evidence still awaiting its first preparation (durable tail work).
    public let hasTrainingPairBuildPending: Bool
    /// Pairs left at an older prompt format, or preparation failures due
    /// for another attempt: background rebuild work that needs the model.
    public let hasTrainingPairRebuildPending: Bool
    /// Eligible current-revision pairs no promoted checkpoint has
    /// incorporated. Meaningful only while a compatible promoted lineage
    /// exists: a stamp left by an earlier training task says nothing about
    /// the current one, so a lineage's first run counts `eligibleTrainingPairCount`.
    public let pendingTrainingTargetCount: Int
    /// Eligible current-revision pairs regardless of promotion stamps.
    public let eligibleTrainingPairCount: Int
    public let trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress
    /// Sent emails whose first preparation under the current prompt format
    /// has not happened: pending (including dispositions an older build
    /// wrote), prepared at an older format, or failed under an older format.
    /// The first full training pass waits for this to reach zero.
    public let outstandingTrainingPreparationCount: Int
    /// Present when the snapshot was taken with a `TrainingHoldScope`: the
    /// training counts above then already exclude held revisions.
    public let trainingHolds: TrainingHolds?
}

/// The training profile whose failure and deferral stamps hold revisions out
/// of the actionability snapshot's training counts.
public struct TrainingHoldScope: Sendable {
    public let trainingProfileID: String
    /// A deferral stamped after this instant is still in force.
    public let deferredSince: Date

    public init(trainingProfileID: String, deferredSince: Date) {
        self.trainingProfileID = trainingProfileID
        self.deferredSince = deferredSince
    }
}

/// Revisions deferred under the snapshot's training profile (and not failed
/// under it), with the earliest deferral stamp, for pending targets and for
/// every eligible pair.
public struct TrainingHolds: Sendable, Equatable {
    public let deferredTargetCount: Int
    public let earliestDeferredTargetAt: Date?
    public let deferredEligibleCount: Int
    public let earliestDeferredEligibleAt: Date?
}

public struct AccountMemoryMessageCounts: Sendable, Equatable {
    public let eligibleMessages: Int
    public let sentMessages: Int
    public let receivedMessages: Int

    public init(
        eligibleMessages: Int,
        sentMessages: Int,
        receivedMessages: Int
    ) {
        self.eligibleMessages = eligibleMessages
        self.sentMessages = sentMessages
        self.receivedMessages = receivedMessages
    }
}

public struct MessageStorePipelineCounts: Sendable {
    public let totalMessages: Int
    public let pendingEmbedding: Int
    public let completedEmbedding: Int

    public init(
        totalMessages: Int,
        pendingEmbedding: Int,
        completedEmbedding: Int
    ) {
        self.totalMessages = totalMessages
        self.pendingEmbedding = pendingEmbedding
        self.completedEmbedding = completedEmbedding
    }
}

public struct MessageStoreInterpretationCounts: Sendable {
    public let completedInterpretation: Int
    public let bodySummaries: Int
    public let pendingInterpretation: Int
    public let embeddedMessages: Int
    public let pendingEmbeddedInterpretation: Int
    public let placedMessages: Int
    public let pendingPlacedInterpretation: Int

    public init(
        completedInterpretation: Int,
        bodySummaries: Int = 0,
        pendingInterpretation: Int,
        embeddedMessages: Int,
        pendingEmbeddedInterpretation: Int,
        placedMessages: Int,
        pendingPlacedInterpretation: Int
    ) {
        self.completedInterpretation = completedInterpretation
        self.bodySummaries = bodySummaries
        self.pendingInterpretation = pendingInterpretation
        self.embeddedMessages = embeddedMessages
        self.pendingEmbeddedInterpretation = pendingEmbeddedInterpretation
        self.placedMessages = placedMessages
        self.pendingPlacedInterpretation = pendingPlacedInterpretation
    }
}

public struct MessageStoreConstellationRecipient: Sendable, Equatable {
    public let emailAddress: String
    public let displayName: String?

    public init(emailAddress: String, displayName: String?) {
        self.emailAddress = emailAddress
        self.displayName = displayName
    }
}

public struct MessageStoreConstellationMessageRow: Sendable, Equatable {
    public let messageId: String
    public let accountId: UUID?
    /// `ZMESSAGETHREAD.ZID` joined via `m.ZTHREAD`. `nil` for messages whose
    /// thread assignment hasn't been backfilled yet (or genuinely standalone
    /// rows). Used by the People-lens layout to size each message's within-band
    /// radial position by its conversation's total length.
    public let threadId: UUID?
    public let messageTypeRaw: String
    public let embeddingStatusRaw: String
    public let subject: String
    public let isRead: Bool
    public let isReplied: Bool
    public let isSentByUser: Bool
    public let flagged: Bool
    public let hasAttachments: Bool
    public let fromAddress: String
    public let fromName: String?
    public let sentAt: Date?
    public let receivedAt: Date?
    public let ingestedAt: Date
    public let liveDetectedAt: Date?
    public let bodyTextPath: String?
    public let bodyHtmlPath: String?
    public let dimensionsJSON: String?
    public let bodySummary: String?
    public let bodySummaryInputFingerprint: String?
    public let mailClassificationJSON: String?
    public let customCategoryKeysJSON: String?
    /// Raw triage signals extracted from `MessageAnalysis.triageVerdictJSON`.
    /// The booleans keep older hot-path consumers cheap; the full JSON and
    /// reply headers let UI snapshots feed the shared message-attention
    /// resolver without crossing back into SwiftData.
    public let triageIsActionable: Bool?
    public let triageRequiresConfirmation: Bool?
    public let triageVerdictJSON: String?
    public let messageIdHeader: String?
    public let inReplyTo: String?
    public let referencesChain: String?
    public let repliedAt: Date?
    public let toRecipients: [MessageStoreConstellationRecipient]
    public let ccRecipients: [MessageStoreConstellationRecipient]
    public let bccRecipients: [MessageStoreConstellationRecipient]
    /// Lowercased email addresses for every non-From participant on the
    /// message — To + Cc + Bcc. Mirrors the set the layout-force path uses
    /// in `MessageGraphEdgeProvider.correspondentSignals` so the
    /// constellation renderer's `.people` major-correspondent check can
    /// agree with the force about which messages share a major
    /// correspondent. Empty when the message has no non-From recipients
    /// (rare; defensive).
    public let recipientAddresses: [String]
    /// Canonical RFC 2919 list identity stamped at ingestion; nil for
    /// non-list mail and rows ingested before list parsing existed.
    public let listId: String?

    public init(
        messageId: String,
        accountId: UUID?,
        threadId: UUID? = nil,
        messageTypeRaw: String,
        embeddingStatusRaw: String,
        subject: String,
        isRead: Bool = false,
        isReplied: Bool,
        isSentByUser: Bool,
        flagged: Bool,
        hasAttachments: Bool,
        fromAddress: String,
        fromName: String?,
        sentAt: Date?,
        receivedAt: Date?,
        ingestedAt: Date,
        liveDetectedAt: Date? = nil,
        bodyTextPath: String?,
        bodyHtmlPath: String?,
        dimensionsJSON: String?,
        bodySummary: String?,
        bodySummaryInputFingerprint: String? = nil,
        mailClassificationJSON: String? = nil,
        customCategoryKeysJSON: String? = nil,
        triageIsActionable: Bool? = nil,
        triageRequiresConfirmation: Bool? = nil,
        triageVerdictJSON: String? = nil,
        messageIdHeader: String? = nil,
        inReplyTo: String? = nil,
        referencesChain: String? = nil,
        repliedAt: Date? = nil,
        toRecipients: [MessageStoreConstellationRecipient],
        ccRecipients: [MessageStoreConstellationRecipient] = [],
        bccRecipients: [MessageStoreConstellationRecipient] = [],
        recipientAddresses: [String] = [],
        listId: String? = nil
    ) {
        self.messageId = messageId
        self.accountId = accountId
        self.threadId = threadId
        self.messageTypeRaw = messageTypeRaw
        self.embeddingStatusRaw = embeddingStatusRaw
        self.subject = subject
        self.isRead = isRead
        self.isReplied = isReplied
        self.isSentByUser = isSentByUser
        self.flagged = flagged
        self.hasAttachments = hasAttachments
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.ingestedAt = ingestedAt
        self.liveDetectedAt = liveDetectedAt
        self.bodyTextPath = bodyTextPath
        self.bodyHtmlPath = bodyHtmlPath
        self.dimensionsJSON = dimensionsJSON
        self.bodySummary = bodySummary
        self.bodySummaryInputFingerprint = bodySummaryInputFingerprint
        self.mailClassificationJSON = mailClassificationJSON
        self.customCategoryKeysJSON = customCategoryKeysJSON
        self.triageIsActionable = triageIsActionable
        self.triageRequiresConfirmation = triageRequiresConfirmation
        self.triageVerdictJSON = triageVerdictJSON
        self.messageIdHeader = messageIdHeader
        self.inReplyTo = inReplyTo
        self.referencesChain = referencesChain
        self.repliedAt = repliedAt
        self.toRecipients = toRecipients
        self.ccRecipients = ccRecipients
        self.bccRecipients = bccRecipients
        self.recipientAddresses = recipientAddresses
        self.listId = listId
    }
}

public struct MessageStoreFrameEdgeRow: Sendable, Equatable {
    public let messageId: String
    public let threadId: UUID?
    public let fromAddress: String
    public let date: Date
    public let isSentByUser: Bool
    public let liveDetectedAt: Date?
    /// Participant addresses excluding `.from` rows when role metadata is
    /// available. Sent-message people edges use these as counterparties
    /// instead of grouping all outbound mail by the user's own address.
    public let participantAddresses: [String]
    public let messageTypeRaw: String
    public let mailClassificationJSON: String?
    public let triageIsActionable: Bool?
    public let triageRequiresConfirmation: Bool?
    public let actionKindRaw: String?
    public let signalKindRaw: String?
    public let dimensionsJSON: String?

    public init(
        messageId: String,
        threadId: UUID?,
        fromAddress: String,
        date: Date,
        isSentByUser: Bool = false,
        liveDetectedAt: Date? = nil,
        participantAddresses: [String] = [],
        messageTypeRaw: String = MessageType.unclassified.rawValue,
        mailClassificationJSON: String? = nil,
        triageIsActionable: Bool? = nil,
        triageRequiresConfirmation: Bool? = nil,
        actionKindRaw: String? = nil,
        signalKindRaw: String? = nil,
        dimensionsJSON: String? = nil
    ) {
        self.messageId = messageId
        self.threadId = threadId
        self.fromAddress = fromAddress
        self.date = date
        self.isSentByUser = isSentByUser
        self.liveDetectedAt = liveDetectedAt
        self.participantAddresses = participantAddresses
        self.messageTypeRaw = messageTypeRaw
        self.mailClassificationJSON = mailClassificationJSON
        self.triageIsActionable = triageIsActionable
        self.triageRequiresConfirmation = triageRequiresConfirmation
        self.actionKindRaw = actionKindRaw
        self.signalKindRaw = signalKindRaw
        self.dimensionsJSON = dimensionsJSON
    }
}

public struct MessageStoreLiveInboundCursor: Sendable, Equatable {
    public let liveDetectedAt: Date
    public let storePrimaryKey: Int64

    public init(liveDetectedAt: Date, storePrimaryKey: Int64) {
        self.liveDetectedAt = liveDetectedAt
        self.storePrimaryKey = storePrimaryKey
    }
}

public struct MessageStoreLiveInboundRow: Sendable, Equatable {
    public let messageId: UUID
    public let accountId: UUID
    public let folder: String?
    public let liveDetectedAt: Date
    public let cursor: MessageStoreLiveInboundCursor
    public let isPipelineReadyForUserAlert: Bool
    /// Set when the layout pipeline wrote world positions for this message's
    /// vectors (`Message.placedAt`). The arrival announcement waits for this
    /// in addition to `isPipelineReadyForUserAlert` so the constellation node,
    /// starburst badge, dock badge, sound, and system notification can all
    /// land in the same moment.
    public let placedAt: Date?

    public init(
        messageId: UUID,
        accountId: UUID,
        folder: String?,
        liveDetectedAt: Date,
        cursor: MessageStoreLiveInboundCursor? = nil,
        isPipelineReadyForUserAlert: Bool = false,
        placedAt: Date? = nil
    ) {
        self.messageId = messageId
        self.accountId = accountId
        self.folder = folder
        self.liveDetectedAt = liveDetectedAt
        self.cursor = cursor ?? MessageStoreLiveInboundCursor(
            liveDetectedAt: liveDetectedAt,
            storePrimaryKey: 0
        )
        self.isPipelineReadyForUserAlert = isPipelineReadyForUserAlert
        self.placedAt = placedAt
    }
}

public struct MessageStoreLiveInboundPage: Sendable, Equatable {
    public let rows: [MessageStoreLiveInboundRow]
    public let nextCursor: MessageStoreLiveInboundCursor?

    public init(
        rows: [MessageStoreLiveInboundRow],
        nextCursor: MessageStoreLiveInboundCursor?
    ) {
        self.rows = rows
        self.nextCursor = nextCursor
    }
}

public enum MessageStoreHotPath {
    private static let busyTimeoutMilliseconds: Int32 = 10_000

    private static func completeClassificationSQL(
        db: OpaquePointer,
        analysisAlias: String
    ) throws -> String {
        guard try tableHasColumn(
            "ZMAILCLASSIFICATIONJSON",
            in: "ZMESSAGEANALYSIS",
            db: db
        ) else {
            return "0"
        }
        let value = "\(analysisAlias).ZMAILCLASSIFICATIONJSON"
        return try MailClassificationSQL.completePredicate(columnReference: value)
    }

    private static func completeInterpretationSQL(
        db: OpaquePointer,
        messageAlias: String = "m",
        analysisAlias: String = "a"
    ) throws -> String {
        let hasLiveInboundColumns = try tableHasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE", db: db)
            && tableHasColumn("ZISSENTBYUSER", in: "ZMESSAGE", db: db)
        let triageRequiredSQL = hasLiveInboundColumns
            ? "\(messageAlias).ZLIVEDETECTEDAT IS NOT NULL AND COALESCE(\(messageAlias).ZISSENTBYUSER, 0) = 0"
            : "0"
        let validTriageSQL = """
        \(analysisAlias).ZTRIAGEVERDICTJSON IS NOT NULL
        AND LENGTH(TRIM(\(analysisAlias).ZTRIAGEVERDICTJSON)) > 0
        AND json_valid(\(analysisAlias).ZTRIAGEVERDICTJSON)
        AND COALESCE(json_type(\(analysisAlias).ZTRIAGEVERDICTJSON, '$.isActionable') IN ('true', 'false'), 0)
        AND COALESCE(json_type(\(analysisAlias).ZTRIAGEVERDICTJSON, '$.requiresConfirmation') IN ('true', 'false'), 0)
        """
        let validClassificationSQL = try completeClassificationSQL(
            db: db,
            analysisAlias: analysisAlias
        )
        return """
        COALESCE((\(validClassificationSQL)), 0)
        AND (NOT (\(triageRequiredSQL)) OR (\(validTriageSQL)))
        """
    }

    public static func defaultStoreURL() -> URL {
        OhiaStorageRoot.required().swiftDataStore
    }

    public static func installHotPathIndexes(storeURL: URL = defaultStoreURL()) throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let ddl = """
        DROP INDEX IF EXISTS idx_ohia_message_analysis_ingested;
        CREATE INDEX IF NOT EXISTS idx_ohia_message_type_ingested
            ON ZMESSAGE(ZMESSAGETYPE, ZINGESTEDAT);
        CREATE INDEX IF NOT EXISTS idx_ohia_message_embedding_ingested
            ON ZMESSAGE(ZEMBEDDINGSTATUS, ZINGESTEDAT);
        DROP INDEX IF EXISTS idx_ohia_message_analysis_pipeline_date;
        DROP INDEX IF EXISTS idx_ohia_message_type_pipeline_date;
        DROP INDEX IF EXISTS idx_ohia_message_embedding_pipeline_date;
        CREATE INDEX IF NOT EXISTS idx_ohia_message_type_pipeline_date
            ON ZMESSAGE(ZMESSAGETYPE, COALESCE(ZRECEIVEDAT, ZSENTAT, ZINGESTEDAT) DESC, ZINGESTEDAT DESC);
        CREATE INDEX IF NOT EXISTS idx_ohia_message_embedding_pipeline_date
            ON ZMESSAGE(ZEMBEDDINGSTATUS, COALESCE(ZRECEIVEDAT, ZSENTAT, ZINGESTEDAT) DESC, ZINGESTEDAT DESC);
        CREATE INDEX IF NOT EXISTS idx_ohia_message_id
            ON ZMESSAGE(ZID);
        CREATE INDEX IF NOT EXISTS idx_ohia_message_sent_training
            ON ZMESSAGE(ZISSENTBYUSER, ZTRAININGSTATUS);
        CREATE INDEX IF NOT EXISTS idx_ohia_message_summary_gate
            ON ZMESSAGE(ZMESSAGETYPE, ZANALYSIS);
        CREATE INDEX IF NOT EXISTS idx_ohia_message_draft_gate
            ON ZMESSAGE(ZMESSAGETYPE, ZANALYSIS, ZDRAFT);
        DROP INDEX IF EXISTS idx_ohia_analysis_summary;
        DROP INDEX IF EXISTS idx_ohia_trainingpair_included;
        CREATE INDEX IF NOT EXISTS idx_ohia_trainingpair_pending_revision
            ON ZTRAININGPAIR(ZEVIDENCEREVISION, ZLATESTPROMOTEDEVIDENCEREVISION, ZEVIDENCE);
        CREATE INDEX IF NOT EXISTS idx_ohia_job_claim
            ON ZJOB(ZSTATUS, ZPRIORITY, ZNEXTATTEMPTAT);
        CREATE INDEX IF NOT EXISTS idx_ohia_outbox_status
            ON ZOUTBOXITEM(ZSTATUS);
        CREATE INDEX IF NOT EXISTS idx_ohia_category_status
            ON ZCATEGORYDEFINITION(ZSTATUS);
        DROP INDEX IF EXISTS idx_ohia_account_status_mail_path;
        CREATE INDEX IF NOT EXISTS idx_ohia_message_constellation_snapshot
            ON ZMESSAGE(Z_PK, ZID, ZACCOUNT, ZANALYSIS, ZTHREAD);
        CREATE INDEX IF NOT EXISTS idx_ohia_messageparticipant_role_message
            ON ZMESSAGEPARTICIPANT(ZROLE, ZMESSAGE);
        CREATE INDEX IF NOT EXISTS idx_ohia_messageparticipant_message_role
            ON ZMESSAGEPARTICIPANT(ZMESSAGE, ZROLE);
        """
        try exec(ddl, db: db)

        if try tableHasColumn(
            "ZMAILCLASSIFICATIONJSON",
            in: "ZMESSAGEANALYSIS",
            db: db
        ) {
            try exec("""
            CREATE INDEX IF NOT EXISTS idx_ohia_analysis_summary
                ON ZMESSAGEANALYSIS(Z_PK, ZMAILCLASSIFICATIONJSON, ZTRIAGEVERDICTJSON);
            """, db: db)
        }

        if try tableHasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE", db: db),
           try tableHasColumn("ZISSENTBYUSER", in: "ZMESSAGE", db: db) {
            try exec("""
            CREATE INDEX IF NOT EXISTS idx_ohia_message_live_inbound
                ON ZMESSAGE(ZLIVEDETECTEDAT, ZISSENTBYUSER)
                WHERE ZLIVEDETECTEDAT IS NOT NULL;
            """, db: db)
        }
        if try tableHasColumn("ZID", in: "ZJOB", db: db) {
            try exec("""
            CREATE INDEX IF NOT EXISTS idx_ohia_job_id
                ON ZJOB(ZID);
            """, db: db)
        }
        // Composer polls preparation jobs by message ID. Without this index,
        // each selected-message refresh scans the entire durable job history
        // synchronously on the UI thread, interrupting departure animations.
        if try tableHasColumn("ZMESSAGEID", in: "ZJOB", db: db) {
            try exec("""
            CREATE INDEX IF NOT EXISTS idx_ohia_job_message
                ON ZJOB(ZMESSAGEID);
            """, db: db)
        }
        if try tableHasColumn("ZTYPE", in: "ZJOB", db: db),
           try tableHasColumn("ZSTATUS", in: "ZJOB", db: db),
           try tableHasColumn("ZPRIORITY", in: "ZJOB", db: db),
           try tableHasColumn("ZNEXTATTEMPTAT", in: "ZJOB", db: db) {
            try exec("""
            CREATE INDEX IF NOT EXISTS idx_ohia_job_type_claim
                ON ZJOB(ZTYPE, ZSTATUS, ZPRIORITY, ZNEXTATTEMPTAT);
            """, db: db)
        }
        // The ingestion tail reads each lane's latest turn end, MAX(ZCOMPLETEDAT)
        // per type, from a job history that is never pruned.
        if try tableHasColumn("ZTYPE", in: "ZJOB", db: db),
           try tableHasColumn("ZSTATUS", in: "ZJOB", db: db),
           try tableHasColumn("ZCOMPLETEDAT", in: "ZJOB", db: db) {
            try exec("""
            CREATE INDEX IF NOT EXISTS idx_ohia_job_type_completed
                ON ZJOB(ZTYPE, ZSTATUS, ZCOMPLETEDAT);
            """, db: db)
        }
    }

    public static func recentLiveInboundRows(
        since: Date,
        after cursor: MessageStoreLiveInboundCursor? = nil,
        limit: Int = 200,
        storeURL: URL = defaultStoreURL()
    ) throws -> [MessageStoreLiveInboundRow]? {
        try recentLiveInboundPage(
            since: since,
            after: cursor,
            limit: limit,
            storeURL: storeURL
        )?.rows
    }

    public static func recentLiveInboundPage(
        since: Date,
        after cursor: MessageStoreLiveInboundCursor? = nil,
        limit: Int = 200,
        storeURL: URL = defaultStoreURL()
    ) throws -> MessageStoreLiveInboundPage? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        // ZPLACEDAT joins the required columns: the arrival pipeline cannot
        // synchronize the alert moment with node visibility without knowing
        // placement, so a store predating placement tracking gets no live
        // alerts at all — same fail-closed behavior as a store predating
        // live-inbound tracking.
        guard try tableHasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE", db: db),
              try tableHasColumn("ZIMAPFOLDERPATH", in: "ZMESSAGE", db: db),
              try tableHasColumn("ZPLACEDAT", in: "ZMESSAGE", db: db) else {
            return MessageStoreLiveInboundPage(rows: [], nextCursor: nil)
        }

        let safeLimit = max(1, limit)
        let accountExpression = try tableHasColumn("ZACCOUNTID", in: "ZMESSAGE", db: db)
            ? "COALESCE(m.ZACCOUNTID, a.ZID)"
            : "a.ZID"
        let completeClassificationSQL = try completeClassificationSQL(
            db: db,
            analysisAlias: "analysis"
        )
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let readyExpression = """
        m.ZEMBEDDINGSTATUS = '\(ProcessingStatus.completed.rawValue)'
        AND analysis.ZBODYSUMMARY IS NOT NULL
        AND LENGTH(TRIM(analysis.ZBODYSUMMARY)) > 0
        AND (\(completeClassificationSQL))
        AND analysis.ZTRIAGEVERDICTJSON IS NOT NULL
        AND LENGTH(TRIM(analysis.ZTRIAGEVERDICTJSON)) > 0
        AND json_valid(analysis.ZTRIAGEVERDICTJSON)
        AND COALESCE(json_type(analysis.ZTRIAGEVERDICTJSON, '$.isActionable') IN ('true', 'false'), 0)
        AND COALESCE(json_type(analysis.ZTRIAGEVERDICTJSON, '$.requiresConfirmation') IN ('true', 'false'), 0)
        """
        let sql = """
        SELECT
            m.Z_PK,
            m.ZID,
            \(accountExpression),
            m.ZIMAPFOLDERPATH,
            m.ZLIVEDETECTEDAT,
            CASE WHEN \(readyExpression) THEN 1 ELSE 0 END,
            m.ZPLACEDAT
        FROM ZMESSAGE m
        LEFT JOIN ZMESSAGEANALYSIS analysis ON analysis.Z_PK = m.ZANALYSIS
        LEFT JOIN ZACCOUNT a ON a.Z_PK = m.ZACCOUNT
        WHERE m.ZLIVEDETECTEDAT IS NOT NULL
          AND \(activeMessageSQL)
          AND m.ZLIVEDETECTEDAT >= ?
          AND (
              ? IS NULL
              OR m.ZLIVEDETECTEDAT > ?
              OR (m.ZLIVEDETECTEDAT = ? AND m.Z_PK > ?)
          )
          AND COALESCE(m.ZISSENTBYUSER, 0) = 0
        ORDER BY m.ZLIVEDETECTEDAT ASC, m.Z_PK ASC
        LIMIT ?;
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, since.timeIntervalSinceReferenceDate)
        if let cursor {
            let cursorTimestamp = cursor.liveDetectedAt.timeIntervalSinceReferenceDate
            sqlite3_bind_double(statement, 2, cursorTimestamp)
            sqlite3_bind_double(statement, 3, cursorTimestamp)
            sqlite3_bind_double(statement, 4, cursorTimestamp)
            sqlite3_bind_int64(statement, 5, cursor.storePrimaryKey)
        } else {
            sqlite3_bind_null(statement, 2)
            sqlite3_bind_null(statement, 3)
            sqlite3_bind_null(statement, 4)
            sqlite3_bind_null(statement, 5)
        }
        sqlite3_bind_int(statement, 6, Int32(safeLimit))

        var rows: [MessageStoreLiveInboundRow] = []
        var rawRowCount = 0
        var lastRawCursor: MessageStoreLiveInboundCursor?
        var stepResult: Int32 = SQLITE_OK
        while true {
            stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else { break }
            rawRowCount += 1
            let storePrimaryKey = sqlite3_column_int64(statement, 0)
            let rawLiveDetectedAt = date(statement, column: 4)
            if let rawLiveDetectedAt {
                lastRawCursor = MessageStoreLiveInboundCursor(
                    liveDetectedAt: rawLiveDetectedAt,
                    storePrimaryKey: storePrimaryKey
                )
            }
            guard let messageId = blobData(statement, column: 1).flatMap(uuid(from:)),
                  let accountId = blobData(statement, column: 2).flatMap(uuid(from:)),
                  let liveDetectedAt = rawLiveDetectedAt else {
                continue
            }
            rows.append(MessageStoreLiveInboundRow(
                messageId: messageId,
                accountId: accountId,
                folder: text(statement, column: 3),
                liveDetectedAt: liveDetectedAt,
                cursor: MessageStoreLiveInboundCursor(
                    liveDetectedAt: liveDetectedAt,
                    storePrimaryKey: storePrimaryKey
                ),
                isPipelineReadyForUserAlert: sqlite3_column_int(statement, 5) != 0,
                placedAt: date(statement, column: 6)
            ))
        }

        guard stepResult == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return MessageStoreLiveInboundPage(
            rows: rows,
            nextCursor: rawRowCount == safeLimit ? lastRawCursor : nil
        )
    }

    /// IDs of messages still missing a complete structured interpretation.
    /// Mirrors the `hasSummaryPending` predicate in `actionabilitySnapshot`.
    /// Ordered newest-first so the user's most recent mail surfaces structured
    /// triage data fastest.
    public static func pendingSummaryMessageIDs(
        limit: Int,
        storeURL: URL = defaultStoreURL()
    ) throws -> [UUID]? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let safeLimit = max(1, limit)
        let completeInterpretationSQL = try completeInterpretationSQL(db: db)
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let sql = """
        SELECT m.ZID
        FROM ZMESSAGE m
        LEFT JOIN ZMESSAGEANALYSIS a ON a.Z_PK = m.ZANALYSIS
        WHERE \(activeMessageSQL)
          AND (m.ZANALYSIS IS NULL OR NOT (\(completeInterpretationSQL)))
        ORDER BY
            COALESCE(m.ZRECEIVEDAT, m.ZSENTAT, m.ZINGESTEDAT) DESC,
            m.ZINGESTEDAT DESC,
            m.ZID ASC
        LIMIT ?;
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(safeLimit))

        var ids: [UUID] = []
        ids.reserveCapacity(safeLimit)
        var stepResult: Int32 = SQLITE_OK
        while true {
            stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else { break }
            guard let data = blobData(statement, column: 0),
                  let id = uuid(from: data) else { continue }
            ids.append(id)
        }
        guard stepResult == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return ids
    }

    /// IDs of messages whose lightweight interpretation is complete but whose
    /// rich hover/expanded-pane body summary has not been generated yet.
    /// Ordered newest-first so the late bulk summary pass fills recent mail
    /// before older historical rows; `newestFirst: false` skips the sort, for
    /// probes that only ask whether some row exists beyond a known few.
    public static func pendingBodySummaryMessageIDs(
        limit: Int,
        newestFirst: Bool = true,
        storeURL: URL = defaultStoreURL()
    ) throws -> [UUID]? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let safeLimit = max(1, limit)
        let completeInterpretationSQL = try completeInterpretationSQL(db: db)
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let orderSQL = newestFirst
            ? "ORDER BY COALESCE(m.ZRECEIVEDAT, m.ZSENTAT, m.ZINGESTEDAT) DESC, m.ZINGESTEDAT DESC, m.ZID ASC"
            : ""
        let sql = """
        SELECT m.ZID
        FROM ZMESSAGE m
        JOIN ZMESSAGEANALYSIS a ON a.Z_PK = m.ZANALYSIS
        WHERE \(activeMessageSQL)
          AND \(completeInterpretationSQL)
          AND (
              a.ZBODYSUMMARY IS NULL
              OR LENGTH(TRIM(a.ZBODYSUMMARY)) = 0
          )
        \(orderSQL)
        LIMIT ?;
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(safeLimit))

        var ids: [UUID] = []
        ids.reserveCapacity(safeLimit)
        var stepResult: Int32 = SQLITE_OK
        while true {
            stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else { break }
            guard let data = blobData(statement, column: 0),
                  let id = uuid(from: data) else { continue }
            ids.append(id)
        }
        guard stepResult == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return ids
    }

    public static func pendingMessageIDs(
        kind: MessageStoreWorkKind,
        limit: Int,
        storeURL: URL = defaultStoreURL()
    ) throws -> [UUID]? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let safeLimit = max(1, limit)
        let activeMessageSQL = try activeMessageSQL(db: db)
        let sql = """
        SELECT ZID
        FROM ZMESSAGE
        WHERE \(activeMessageSQL)
          AND \(kind.whereSQL)
        ORDER BY
            COALESCE(ZRECEIVEDAT, ZSENTAT, ZINGESTEDAT) DESC,
            ZINGESTEDAT DESC,
            ZID ASC
        LIMIT ?;
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        let bindValues = kind.bindValues
        for (index, value) in bindValues.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, OHIA_SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(statement, Int32(bindValues.count + 1), Int32(safeLimit))

        var ids: [UUID] = []
        ids.reserveCapacity(safeLimit)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = blobData(statement, column: 0),
                  let id = uuid(from: data) else { continue }
            ids.append(id)
        }
        return ids
    }

    /// `trainingHolds` makes the training counts exact for one training
    /// profile: revisions whose training failed, or that are deferred, under
    /// it are held out of the pending and eligible counts. Without it those
    /// counts are upper bounds.
    public static func actionabilitySnapshot(
        storeURL: URL = defaultStoreURL(),
        automaticTriageQueueingEnabled: Bool = ComposerQueueIntakePreference.automaticTriageQueueingEnabled(),
        trainingHolds: TrainingHoldScope? = nil
    ) throws -> MessageStoreActionabilitySnapshot? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let completeInterpretationSQL = try completeInterpretationSQL(db: db)
        let activeUnaliasedMessageSQL = try activeMessageSQL(db: db)
        let activeAliasedMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let draftEligibleSQL = try tableHasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE", db: db)
            ? "ZLIVEDETECTEDAT IS NOT NULL AND COALESCE(ZISSENTBYUSER, 0) = 0"
            : "0"
        // A superset prefilter of Message.isComposerQueueEligible, which then
        // decides: this mirrors one email's own queue decision — a user
        // "Needs Reply" include wins, an explicit exclude removes, and the
        // automatic path requires actionable + live-inbound + still requiring
        // a reply when Settings allows automatic triage queueing. A
        // conversation's item that still has no Draft always qualifies
        // itself, so the per-conversation choice of item is left to the Swift
        // check the caller ANDs with this.
        // Columns are guarded because this read-only path can run against a
        // store the app process hasn't migrated yet.
        let hasOverrideColumn = try tableHasColumn("ZCOMPOSERQUEUEOVERRIDERAW", in: "ZMESSAGE", db: db)
        let overrideIncludeSQL = hasOverrideColumn
            ? "(ZCOMPOSERQUEUEOVERRIDERAW = 'include' AND COALESCE(ZISSENTBYUSER, 0) = 0)"
            : "0"
        let overrideNotExcludedSQL = hasOverrideColumn
            ? "COALESCE(ZCOMPOSERQUEUEOVERRIDERAW, '') <> 'exclude'"
            : "1"
        let requiresReplySQL = try tableHasColumn("ZREQUIRESREPLY", in: "ZMESSAGE", db: db)
            ? "COALESCE(ZREQUIRESREPLY, 1) = 1"
            : "1"
        // Preparation admission keys on the evidence ledger the builder
        // actually drains — not on reply-shaped pending messages. Gating on
        // replies starved standalone evidence forever once the reply backlog
        // finished, leaving permanent `pendingPreparation` rows.
        let hasEvidenceTable = try tableHasColumn(
            "ZDISPOSITIONRAW",
            in: "ZSENTTRAININGEVIDENCE",
            db: db
        )
        // A disposition an older build wrote that the current ledger no
        // longer names is pending preparation too: the builder re-prepares it.
        let settledDispositions = [
            SentTrainingEvidenceDisposition.loraEligible,
            .excluded,
            .preparationFailed,
        ].map { "'\($0.rawValue)'" }.joined(separator: ", ")
        let pendingPreparationSQL = hasEvidenceTable
            ? "EXISTS(SELECT 1 FROM ZSENTTRAININGEVIDENCE WHERE ZDISPOSITIONRAW NOT IN (\(settledDispositions)) LIMIT 1)"
            : "0"
        let hasTrainingRoleColumn = try tableHasColumn(
            "ZTRAININGROLERAW",
            in: "ZTRAININGPAIR",
            db: db
        )
        let hasPromptFormatColumn = try tableHasColumn(
            "ZPROMPTFORMATVERSION",
            in: "ZTRAININGPAIR",
            db: db
        )
        // A pair built at an older prompt format is not trainable until the
        // preparation job rebuilds it; such pairs are pending preparation
        // work, not pending training targets.
        let currentFormatSQL = hasPromptFormatColumn
            ? "AND COALESCE(p.ZPROMPTFORMATVERSION, 0) = \(TrainingPromptFormat.current)"
            : ""
        let hasEvidenceRevisionColumn = try tableHasColumn("ZEVIDENCEREVISION", in: "ZTRAININGPAIR", db: db)
            && tableHasColumn("ZEVIDENCE", in: "ZTRAININGPAIR", db: db)
        let staleFormatPairsSQL = hasEvidenceTable && hasPromptFormatColumn && hasEvidenceRevisionColumn
            ? """
            EXISTS(
                SELECT 1 FROM ZTRAININGPAIR p
                JOIN ZSENTTRAININGEVIDENCE e ON p.ZEVIDENCE = e.Z_PK
                WHERE e.ZDISPOSITIONRAW = '\(SentTrainingEvidenceDisposition.loraEligible.rawValue)'
                  AND p.ZEVIDENCEREVISION = e.ZREVISION
                  AND COALESCE(p.ZPROMPTFORMATVERSION, 0) < \(TrainingPromptFormat.current)
                LIMIT 1
            )
            """
            : "0"
        let hasRetryColumns = try tableHasColumn("ZISRETRYABLE", in: "ZSENTTRAININGEVIDENCE", db: db)
            && tableHasColumn("ZPREPARATIONATTEMPTEDAT", in: "ZSENTTRAININGEVIDENCE", db: db)
        let hasTaskVersionColumn = try tableHasColumn("ZPREPARATIONTASKVERSION", in: "ZSENTTRAININGEVIDENCE", db: db)
        // A retryable failure (a deadline, a parent not yet ingested) is due
        // again after an hour; a failure recorded under an older prompt
        // format is due once under the current one.
        let retryDeadline = Date().timeIntervalSinceReferenceDate - SentTrainingEvidence.preparationRetryInterval
        let olderTaskSQL = hasTaskVersionColumn
            ? "OR COALESCE(ZPREPARATIONTASKVERSION, 0) < \(TrainingPromptFormat.current)"
            : ""
        // A rejection under the earlier writer-window notes reserve is decided
        // once more under the bounded reserve (`TrainingPairBuilder.isRetryDue`).
        let hasReasonColumn = try tableHasColumn("ZREASONRAW", in: "ZSENTTRAININGEVIDENCE", db: db)
        let earlierReserveSQL = hasReasonColumn
            ? "OR ZREASONRAW = '\(SentTrainingEvidenceReason.exceedsWriterWindow.rawValue)'"
            : ""
        let retryDueSQL = hasEvidenceTable && hasRetryColumns
            ? "EXISTS(SELECT 1 FROM ZSENTTRAININGEVIDENCE WHERE ZDISPOSITIONRAW = '\(SentTrainingEvidenceDisposition.preparationFailed.rawValue)' AND ((ZISRETRYABLE = 1 AND COALESCE(ZPREPARATIONATTEMPTEDAT, 0) < \(retryDeadline)) \(olderTaskSQL) \(earlierReserveSQL)) LIMIT 1)"
            : "0"
        // A pair training rejected at its current revision whose recorded
        // length exceeds the writer window, or that predates recorded lengths,
        // is rebuilt with the window applied (`TrainingPairBuilder.overWindowCandidate`).
        let hasFailureLengthColumns = try tableHasColumn("ZLATESTFAILEDSEQUENCETOKENS", in: "ZTRAININGPAIR", db: db)
            && tableHasColumn("ZLATESTFAILEDEVIDENCEREVISION", in: "ZTRAININGPAIR", db: db)
        let overWindowPairsSQL = hasEvidenceTable && hasEvidenceRevisionColumn && hasFailureLengthColumns
            ? """
            EXISTS(
                SELECT 1 FROM ZTRAININGPAIR p
                JOIN ZSENTTRAININGEVIDENCE e ON p.ZEVIDENCE = e.Z_PK
                WHERE e.ZDISPOSITIONRAW = '\(SentTrainingEvidenceDisposition.loraEligible.rawValue)'
                  AND p.ZEVIDENCEREVISION = e.ZREVISION
                  AND p.ZLATESTFAILEDEVIDENCEREVISION = p.ZEVIDENCEREVISION
                  AND (p.ZLATESTFAILEDSEQUENCETOKENS IS NULL
                       OR p.ZLATESTFAILEDSEQUENCETOKENS > \(TrainingPromptFormat.writerSequenceTokens))
                LIMIT 1
            )
            """
            : "0"
        let rebuildPendingSQL = "(\(staleFormatPairsSQL) OR \(retryDueSQL) OR \(overWindowPairsSQL))"
        // Mirrors `TrainingPairBuilder.outstandingPreparationCount`.
        let olderFormatFailureSQL = hasTaskVersionColumn
            ? "OR (e.ZDISPOSITIONRAW = '\(SentTrainingEvidenceDisposition.preparationFailed.rawValue)' AND COALESCE(e.ZPREPARATIONTASKVERSION, 0) < \(TrainingPromptFormat.current))"
            : ""
        let olderFormatPairSQL = hasPromptFormatColumn && hasEvidenceRevisionColumn
            ? """
              OR (e.ZDISPOSITIONRAW = '\(SentTrainingEvidenceDisposition.loraEligible.rawValue)' AND EXISTS(
                  SELECT 1 FROM ZTRAININGPAIR p
                  WHERE p.ZEVIDENCE = e.Z_PK
                    AND p.ZEVIDENCEREVISION = e.ZREVISION
                    AND COALESCE(p.ZPROMPTFORMATVERSION, 0) < \(TrainingPromptFormat.current)))
              """
            : ""
        let outstandingPreparationSQL = hasEvidenceTable
            ? """
              (SELECT COUNT(*) FROM ZSENTTRAININGEVIDENCE e
               WHERE e.ZDISPOSITIONRAW NOT IN (\(settledDispositions))
                  \(olderFormatFailureSQL)
                  \(olderFormatPairSQL))
              """
            : "0"
        let pendingEvidenceSQL = pendingPreparationSQL
        let trainablePairSQL = (hasTrainingRoleColumn
            ? "AND COALESCE(p.ZTRAININGROLERAW, '') <> '\(TrainingPairRole.validationHoldout.rawValue)'"
            : "") + " " + currentFormatSQL
        let hasTrainingTextColumns = try tableHasColumn(
            "ZPROMPTTEXT",
            in: "ZTRAININGPAIR",
            db: db
        ) && tableHasColumn("ZCOMPLETIONTEXT", in: "ZTRAININGPAIR", db: db)
        let usableTrainingTextSQL = hasTrainingTextColumns
            ? "AND LENGTH(TRIM(COALESCE(p.ZPROMPTTEXT, ''))) > 0 AND LENGTH(TRIM(COALESCE(p.ZCOMPLETIONTEXT, ''))) > 0"
            : ""
        let hasTrainingPairMessageColumn = try tableHasColumn(
            "ZMESSAGE",
            in: "ZTRAININGPAIR",
            db: db
        )
        let activeTrainingPairMessageSQL = hasTrainingPairMessageColumn
            ? "AND (p.ZMESSAGE IS NULL OR EXISTS (SELECT 1 FROM ZMESSAGE m WHERE m.Z_PK = p.ZMESSAGE AND \(activeAliasedMessageSQL)))"
            : ""
        let hasTrainingPairReplySourceColumn = try tableHasColumn(
            "ZREPLYTOMESSAGEID",
            in: "ZTRAININGPAIR",
            db: db
        )
        let hasMessageTrashColumn = try tableHasColumn(
            "ZTRASHEDAT",
            in: "ZMESSAGE",
            db: db
        )
        let activeTrainingPairReplySourceSQL = hasTrainingPairReplySourceColumn && hasMessageTrashColumn
            ? "AND NOT EXISTS (SELECT 1 FROM ZMESSAGE incoming WHERE incoming.ZID = p.ZREPLYTOMESSAGEID AND incoming.ZTRASHEDAT IS NOT NULL)"
            : ""
        let hasTrainingPairProgressSchema = try tableHasColumn(
            "ZEVIDENCE",
            in: "ZTRAININGPAIR",
            db: db
        ) && tableHasColumn(
            "ZEVIDENCEREVISION",
            in: "ZTRAININGPAIR",
            db: db
        ) && tableHasColumn(
            "ZLATESTPROMOTEDEVIDENCEREVISION",
            in: "ZTRAININGPAIR",
            db: db
        )
        let hasEvidenceDateColumns = try tableHasColumn(
            "ZSENTAT",
            in: "ZSENTTRAININGEVIDENCE",
            db: db
        ) && tableHasColumn(
            "ZCREATEDAT",
            in: "ZSENTTRAININGEVIDENCE",
            db: db
        )
        let currentEvidenceSQL = hasEvidenceDateColumns
            ? "AND COALESCE(e.ZSENTAT, e.ZCREATEDAT) <= \(Date().timeIntervalSinceReferenceDate)"
            : ""
        let trainingEvidenceProgressCTE: String
        if hasEvidenceTable, hasTrainingPairProgressSchema {
            trainingEvidenceProgressCTE = """
            WITH training_evidence_progress AS (
                SELECT
                    e.Z_PK AS evidence_id,
                    e.ZDISPOSITIONRAW AS disposition,
                    COUNT(p.Z_PK) AS eligible_pair_count,
                    COALESCE(SUM(
                        CASE WHEN p.Z_PK IS NOT NULL AND (
                            p.ZLATESTPROMOTEDEVIDENCEREVISION IS NULL
                            OR p.ZLATESTPROMOTEDEVIDENCEREVISION <> p.ZEVIDENCEREVISION
                        ) THEN 1 ELSE 0 END
                    ), 0) AS untrained_pair_count
                FROM ZSENTTRAININGEVIDENCE e
                LEFT JOIN ZTRAININGPAIR p
                  ON p.ZEVIDENCE = e.Z_PK
                 AND p.ZEVIDENCEREVISION = e.ZREVISION
                 \(currentEvidenceSQL)
                 \(trainablePairSQL)
                 \(usableTrainingTextSQL)
                 \(activeTrainingPairMessageSQL)
                 \(activeTrainingPairReplySourceSQL)
                GROUP BY e.Z_PK, e.ZDISPOSITIONRAW
            )
            """
        } else if hasEvidenceTable {
            trainingEvidenceProgressCTE = """
            WITH training_evidence_progress AS (
                SELECT
                    e.Z_PK AS evidence_id,
                    e.ZDISPOSITIONRAW AS disposition,
                    0 AS eligible_pair_count,
                    0 AS untrained_pair_count
                FROM ZSENTTRAININGEVIDENCE e
            )
            """
        } else {
            trainingEvidenceProgressCTE = """
            WITH training_evidence_progress AS (
                SELECT
                    NULL AS evidence_id,
                    '' AS disposition,
                    0 AS eligible_pair_count,
                    0 AS untrained_pair_count
                WHERE 0
            )
            """
        }
        // Revisions whose training failed, or that are deferred, under the
        // scope's profile, among exactly the pairs the progress CTE counts.
        let holdColumns = [
            "ZLATESTFAILEDEVIDENCEREVISION", "ZLATESTFAILEDTRAININGPROFILEID",
            "ZLATESTDEFERREDEVIDENCEREVISION", "ZLATESTDEFERREDTRAININGPROFILEID", "ZLATESTDEFERREDAT",
        ]
        let holdScope: TrainingHoldScope? = try trainingHolds.flatMap { scope in
            guard hasEvidenceTable, hasTrainingPairProgressSchema,
                  try holdColumns.allSatisfy({ try tableHasColumn($0, in: "ZTRAININGPAIR", db: db) }) else { return nil }
            return scope
        }
        let trainingHoldsCTE: String
        let trainingHoldsColumnsSQL: String
        if let holdScope {
            // The profile is compared as a hex literal cast to text: safe for
            // any profile string without disturbing the positional parameters.
            let profile = "CAST(X'" + Data(holdScope.trainingProfileID.utf8)
                .map { String(format: "%02x", $0) }.joined() + "' AS TEXT)"
            let deferredSince = holdScope.deferredSince.timeIntervalSinceReferenceDate
            trainingHoldsCTE = """
            , training_pair_flags AS (
                SELECT
                    COALESCE(p.ZLATESTFAILEDEVIDENCEREVISION = p.ZEVIDENCEREVISION
                        AND p.ZLATESTFAILEDTRAININGPROFILEID = \(profile), 0) AS failed,
                    COALESCE(p.ZLATESTDEFERREDEVIDENCEREVISION = p.ZEVIDENCEREVISION
                        AND p.ZLATESTDEFERREDTRAININGPROFILEID = \(profile)
                        AND COALESCE(p.ZLATESTDEFERREDAT, -1e300) > \(deferredSince), 0) AS deferred,
                    (p.ZLATESTPROMOTEDEVIDENCEREVISION IS NULL
                        OR p.ZLATESTPROMOTEDEVIDENCEREVISION <> p.ZEVIDENCEREVISION) AS untrained,
                    p.ZLATESTDEFERREDAT AS deferred_at
                FROM ZTRAININGPAIR p
                JOIN ZSENTTRAININGEVIDENCE e
                  ON p.ZEVIDENCE = e.Z_PK
                 AND p.ZEVIDENCEREVISION = e.ZREVISION
                WHERE e.ZDISPOSITIONRAW = '\(SentTrainingEvidenceDisposition.loraEligible.rawValue)'
                 \(currentEvidenceSQL)
                 \(trainablePairSQL)
                 \(usableTrainingTextSQL)
                 \(activeTrainingPairMessageSQL)
                 \(activeTrainingPairReplySourceSQL)
            ),
            training_pair_holds AS (
                SELECT
                    COALESCE(SUM(CASE WHEN failed OR deferred THEN 1 ELSE 0 END), 0) AS held_eligible,
                    COALESCE(SUM(CASE WHEN (failed OR deferred) AND untrained THEN 1 ELSE 0 END), 0) AS held_untrained,
                    COALESCE(SUM(CASE WHEN deferred AND NOT failed THEN 1 ELSE 0 END), 0) AS deferred_eligible,
                    MIN(CASE WHEN deferred AND NOT failed THEN deferred_at END) AS earliest_deferred_eligible,
                    COALESCE(SUM(CASE WHEN deferred AND NOT failed AND untrained THEN 1 ELSE 0 END), 0) AS deferred_untrained,
                    MIN(CASE WHEN deferred AND NOT failed AND untrained THEN deferred_at END) AS earliest_deferred_untrained
                FROM training_pair_flags
            )
            """
            trainingHoldsColumnsSQL = ["held_eligible", "held_untrained", "deferred_eligible",
                                       "earliest_deferred_eligible", "deferred_untrained", "earliest_deferred_untrained"]
                .map { "(SELECT \($0) FROM training_pair_holds)" }.joined(separator: ", ")
        } else {
            trainingHoldsCTE = ""
            trainingHoldsColumnsSQL = "0, 0, 0, NULL, 0, NULL"
        }
        let automaticQueueSQL = automaticTriageQueueingEnabled
            ? "(ZMESSAGETYPE = ? AND \(draftEligibleSQL) AND \(requiresReplySQL))"
            : "0"
        let hasReplyPreparationSchema = try tableHasColumn(
            "ZMESSAGEID",
            in: "ZREPLYSOURCEPREPARATION",
            db: db
        ) && tableHasColumn(
            "ZSTATUSRAW",
            in: "ZREPLYSOURCEPREPARATION",
            db: db
        )
        let draftPreparationExclusionSQL = hasReplyPreparationSchema
            ? """
              AND NOT EXISTS (
                  SELECT 1
                  FROM ZREPLYSOURCEPREPARATION p
                  WHERE p.ZMESSAGEID = m.ZID
              )
              """
            : ""
        let pendingReplyPreparationSQL = hasReplyPreparationSchema
            ? """
              EXISTS(
                  SELECT 1
                  FROM ZREPLYSOURCEPREPARATION p
                  JOIN ZMESSAGE m ON m.ZID = p.ZMESSAGEID
                  WHERE p.ZSTATUSRAW = '\(ReplySourcePreparationStatus.pending)'
                    AND \(activeAliasedMessageSQL)
                  LIMIT 1
              )
              """
            : "0"
        let sql = """
        \(trainingEvidenceProgressCTE)
        \(trainingHoldsCTE)
        SELECT
            (SELECT COUNT(*) FROM ZMESSAGE WHERE \(activeUnaliasedMessageSQL)),
            EXISTS(
                SELECT 1
                FROM ZMESSAGE
                WHERE \(activeUnaliasedMessageSQL)
                  AND ZEMBEDDINGSTATUS IN (?, ?, ?)
                LIMIT 1
            ),
            EXISTS(
                SELECT 1
                FROM ZMESSAGE m
                LEFT JOIN ZMESSAGEANALYSIS a ON a.Z_PK = m.ZANALYSIS
                WHERE \(activeAliasedMessageSQL)
                  AND (m.ZANALYSIS IS NULL OR NOT (\(completeInterpretationSQL)))
                LIMIT 1
            ),
            EXISTS(
                SELECT 1
                FROM ZMESSAGE m
                JOIN ZMESSAGEANALYSIS a ON a.Z_PK = m.ZANALYSIS
                WHERE \(activeAliasedMessageSQL)
                  AND \(completeInterpretationSQL)
                  AND (
                      a.ZBODYSUMMARY IS NULL
                      OR LENGTH(TRIM(a.ZBODYSUMMARY)) = 0
                  )
                LIMIT 1
            ),
            EXISTS(
                SELECT 1
                FROM ZMESSAGE m
                WHERE \(activeAliasedMessageSQL)
                  AND m.ZANALYSIS IS NOT NULL
                  AND m.ZDRAFT IS NULL
                  AND \(overrideNotExcludedSQL)
                  AND (
                      \(overrideIncludeSQL)
                      OR \(automaticQueueSQL)
                  )
                  \(draftPreparationExclusionSQL)
                LIMIT 1
            ),
            \(pendingReplyPreparationSQL),
            \(pendingEvidenceSQL),
            \(rebuildPendingSQL),
            (SELECT COALESCE(SUM(untrained_pair_count), 0)
             FROM training_evidence_progress
             WHERE disposition = '\(SentTrainingEvidenceDisposition.loraEligible.rawValue)'),
            (SELECT COALESCE(SUM(eligible_pair_count), 0)
             FROM training_evidence_progress
             WHERE disposition = '\(SentTrainingEvidenceDisposition.loraEligible.rawValue)'),
            (SELECT COUNT(*) FROM training_evidence_progress),
            (SELECT COUNT(*)
             FROM training_evidence_progress
             WHERE disposition IN (\(settledDispositions))),
            (SELECT COUNT(*)
             FROM training_evidence_progress
             WHERE disposition = '\(SentTrainingEvidenceDisposition.loraEligible.rawValue)'
               AND eligible_pair_count > 0),
            (SELECT COUNT(*)
             FROM training_evidence_progress
             WHERE disposition = '\(SentTrainingEvidenceDisposition.loraEligible.rawValue)'
               AND eligible_pair_count > 0
               AND untrained_pair_count = 0),
            \(outstandingPreparationSQL),
            \(trainingHoldsColumnsSQL);
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        var values = [
            ProcessingStatus.pending.rawValue,
            ProcessingStatus.processing.rawValue,
            ProcessingStatus.failed.rawValue
        ]
        if automaticTriageQueueingEnabled {
            values.append(MessageType.actionable.rawValue)
        }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, OHIA_SQLITE_TRANSIENT)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(statement, column) == SQLITE_NULL
                ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
        }
        let heldEligible = Int(sqlite3_column_int64(statement, 15))
        let heldUntrained = Int(sqlite3_column_int64(statement, 16))
        return MessageStoreActionabilitySnapshot(
            totalMessages: Int(sqlite3_column_int64(statement, 0)),
            hasEmbeddingPending: sqlite3_column_int(statement, 1) != 0,
            hasSummaryPending: sqlite3_column_int(statement, 2) != 0,
            hasBodySummaryPending: sqlite3_column_int(statement, 3) != 0,
            hasDraftPending: sqlite3_column_int(statement, 4) != 0,
            hasReplySourcePreparationPending: sqlite3_column_int(statement, 5) != 0,
            hasTrainingPairBuildPending: sqlite3_column_int(statement, 6) != 0,
            hasTrainingPairRebuildPending: sqlite3_column_int(statement, 7) != 0,
            pendingTrainingTargetCount: max(0, Int(sqlite3_column_int64(statement, 8)) - heldUntrained),
            eligibleTrainingPairCount: max(0, Int(sqlite3_column_int64(statement, 9)) - heldEligible),
            trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress(
                discoveredMessageCount: Int(sqlite3_column_int64(statement, 10)),
                assessedMessageCount: Int(sqlite3_column_int64(statement, 11)),
                eligibleMessageCount: Int(sqlite3_column_int64(statement, 12)),
                trainedMessageCount: Int(sqlite3_column_int64(statement, 13))
            ),
            outstandingTrainingPreparationCount: Int(sqlite3_column_int64(statement, 14)),
            trainingHolds: holdScope == nil ? nil : TrainingHolds(
                deferredTargetCount: Int(sqlite3_column_int64(statement, 19)),
                earliestDeferredTargetAt: date(20),
                deferredEligibleCount: Int(sqlite3_column_int64(statement, 17)),
                earliestDeferredEligibleAt: date(18)
            )
        )
    }

    public static func initialIngestionCoreBacklogExists(
        storeURL: URL = defaultStoreURL()
    ) throws -> Bool? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let nonLiveSQL = try tableHasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE", db: db)
            ? "m.ZLIVEDETECTEDAT IS NULL"
            : "1"
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let completeInterpretationSQL = try completeInterpretationSQL(db: db)
        let sql = """
        SELECT EXISTS(
            SELECT 1
            FROM ZMESSAGE m
            LEFT JOIN ZMESSAGEANALYSIS a ON a.Z_PK = m.ZANALYSIS
            WHERE \(activeMessageSQL)
              AND \(nonLiveSQL)
              AND (
                  m.ZEMBEDDINGSTATUS <> ?
                  OR m.ZANALYSIS IS NULL
                  OR NOT (\(completeInterpretationSQL))
              )
            LIMIT 1
        );
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ProcessingStatus.completed.rawValue, -1, OHIA_SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    public static func nonLiveMessageExists(
        messageIDs: [UUID],
        storeURL: URL = defaultStoreURL()
    ) throws -> Bool? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }
        guard !messageIDs.isEmpty else { return false }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let nonLiveSQL = try tableHasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE", db: db)
            ? "ZLIVEDETECTEDAT IS NULL"
            : "1"
        let activeMessageSQL = try activeMessageSQL(db: db)
        let batchSize = 400
        for start in stride(from: 0, to: messageIDs.count, by: batchSize) {
            let end = min(start + batchSize, messageIDs.count)
            let batch = messageIDs[start..<end]
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let statement = try prepare("""
            SELECT
                COUNT(*),
                COALESCE(MAX(CASE WHEN \(nonLiveSQL) THEN 1 ELSE 0 END), 0)
            FROM ZMESSAGE
            WHERE \(activeMessageSQL)
              AND ZID IN (\(placeholders));
            """, db: db)
            defer { sqlite3_finalize(statement) }

            for (offset, messageID) in batch.enumerated() {
                try bindUUID(messageID, to: statement, index: Int32(offset + 1))
            }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            let matchedCount = Int(sqlite3_column_int64(statement, 0))
            if matchedCount != batch.count || sqlite3_column_int(statement, 1) != 0 {
                return true
            }
        }
        return false
    }

    /// Returns the subset of candidate IDs that still have an active Message
    /// row. This lets derived sidecar stores discard orphaned rows after an
    /// interrupted deletion instead of allowing their counts to stand in for
    /// a different, genuinely unprocessed message.
    public static func activeMessageIDs(
        matching messageIDs: [UUID],
        storeURL: URL = defaultStoreURL()
    ) throws -> Set<UUID>? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }
        let uniqueMessageIDs = Array(Set(messageIDs))
        guard !uniqueMessageIDs.isEmpty else { return [] }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let activeMessageSQL = try activeMessageSQL(db: db)
        let batchSize = 400
        var activeMessageIDs = Set<UUID>()
        for start in stride(from: 0, to: uniqueMessageIDs.count, by: batchSize) {
            let end = min(start + batchSize, uniqueMessageIDs.count)
            let batch = uniqueMessageIDs[start..<end]
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let statement = try prepare("""
            SELECT ZID
            FROM ZMESSAGE
            WHERE \(activeMessageSQL)
              AND ZID IN (\(placeholders));
            """, db: db)
            defer { sqlite3_finalize(statement) }

            for (offset, messageID) in batch.enumerated() {
                try bindUUID(messageID, to: statement, index: Int32(offset + 1))
            }

            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let data = blobData(statement, column: 0),
                      let messageID = uuid(from: data) else {
                    return nil
                }
                activeMessageIDs.insert(messageID)
                stepResult = sqlite3_step(statement)
            }
            guard stepResult == SQLITE_DONE else {
                throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        return activeMessageIDs
    }

    public static func accountMemoryMessageCounts(
        accountID: UUID,
        storeURL: URL = defaultStoreURL()
    ) throws -> AccountMemoryMessageCounts? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let accountExpression = try tableHasColumn("ZACCOUNTID", in: "ZMESSAGE", db: db)
            ? "COALESCE(m.ZACCOUNTID, account.ZID)"
            : "account.ZID"
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let sql = """
        SELECT
            COUNT(*),
            COALESCE(SUM(CASE WHEN COALESCE(m.ZISSENTBYUSER, 0) = 1 THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN COALESCE(m.ZISSENTBYUSER, 0) = 1 THEN 0 ELSE 1 END), 0)
        FROM ZMESSAGE m
        JOIN ZMESSAGEANALYSIS analysis ON analysis.Z_PK = m.ZANALYSIS
        LEFT JOIN ZACCOUNT account ON account.Z_PK = m.ZACCOUNT
        WHERE \(accountExpression) = ?
          AND \(activeMessageSQL)
          AND analysis.ZBODYSUMMARY IS NOT NULL
          AND LENGTH(TRIM(analysis.ZBODYSUMMARY)) > 0
          AND (m.ZRECEIVEDAT IS NOT NULL OR m.ZSENTAT IS NOT NULL);
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        try bindUUID(accountID, to: statement, index: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return AccountMemoryMessageCounts(
            eligibleMessages: Int(sqlite3_column_int64(statement, 0)),
            sentMessages: Int(sqlite3_column_int64(statement, 1)),
            receivedMessages: Int(sqlite3_column_int64(statement, 2))
        )
    }

    public static func pipelineCounts(
        storeURL: URL = defaultStoreURL()
    ) throws -> MessageStorePipelineCounts? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let activeMessageSQL = try activeMessageSQL(db: db)
        let sql = """
        SELECT
            COUNT(*),
            COALESCE(SUM(CASE WHEN ZEMBEDDINGSTATUS IN (?, ?, ?) THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN ZEMBEDDINGSTATUS = ? THEN 1 ELSE 0 END), 0)
        FROM ZMESSAGE
        WHERE \(activeMessageSQL);
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        let values = [
            ProcessingStatus.pending.rawValue,
            ProcessingStatus.processing.rawValue,
            ProcessingStatus.failed.rawValue,
            ProcessingStatus.completed.rawValue
        ]
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, OHIA_SQLITE_TRANSIENT)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return MessageStorePipelineCounts(
            totalMessages: Int(sqlite3_column_int64(statement, 0)),
            pendingEmbedding: Int(sqlite3_column_int64(statement, 1)),
            completedEmbedding: Int(sqlite3_column_int64(statement, 2))
        )
    }

    public static func interpretedEmbeddingBacklogCount(
        storeURL: URL = defaultStoreURL()
    ) throws -> Int? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let completeInterpretationSQL = try completeInterpretationSQL(db: db)
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let sql = """
        SELECT COUNT(*)
        FROM ZMESSAGE m
        JOIN ZMESSAGEANALYSIS a ON a.Z_PK = m.ZANALYSIS
        WHERE \(activeMessageSQL)
          AND m.ZEMBEDDINGSTATUS IN (?, ?)
          AND \(completeInterpretationSQL);
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        let values = [
            ProcessingStatus.pending.rawValue,
            ProcessingStatus.processing.rawValue
        ]
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, OHIA_SQLITE_TRANSIENT)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    public static func interpretationCounts(
        storeURL: URL = defaultStoreURL()
    ) throws -> MessageStoreInterpretationCounts? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let completeInterpretationSQL = try completeInterpretationSQL(db: db)
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let hasPlacedAtColumn = try tableHasColumn("ZPLACEDAT", in: "ZMESSAGE", db: db)
        let placedCondition = hasPlacedAtColumn ? "m.ZPLACEDAT IS NOT NULL" : "0"
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN m.ZANALYSIS IS NOT NULL AND \(completeInterpretationSQL) THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN m.ZANALYSIS IS NOT NULL AND a.ZBODYSUMMARY IS NOT NULL AND LENGTH(TRIM(a.ZBODYSUMMARY)) > 0 THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN m.ZANALYSIS IS NULL OR NOT (\(completeInterpretationSQL)) THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN m.ZEMBEDDINGSTATUS = ? THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN m.ZEMBEDDINGSTATUS = ? AND (m.ZANALYSIS IS NULL OR NOT (\(completeInterpretationSQL))) THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN \(placedCondition) AND m.ZEMBEDDINGSTATUS = ? THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN \(placedCondition) AND m.ZEMBEDDINGSTATUS = ? AND (m.ZANALYSIS IS NULL OR NOT (\(completeInterpretationSQL))) THEN 1 ELSE 0 END), 0)
        FROM ZMESSAGE m
        LEFT JOIN ZMESSAGEANALYSIS a ON a.Z_PK = m.ZANALYSIS
        WHERE \(activeMessageSQL);
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        let completed = ProcessingStatus.completed.rawValue
        for index in 1...4 {
            sqlite3_bind_text(statement, Int32(index), completed, -1, OHIA_SQLITE_TRANSIENT)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return MessageStoreInterpretationCounts(
            completedInterpretation: Int(sqlite3_column_int64(statement, 0)),
            bodySummaries: Int(sqlite3_column_int64(statement, 1)),
            pendingInterpretation: Int(sqlite3_column_int64(statement, 2)),
            embeddedMessages: Int(sqlite3_column_int64(statement, 3)),
            pendingEmbeddedInterpretation: Int(sqlite3_column_int64(statement, 4)),
            placedMessages: Int(sqlite3_column_int64(statement, 5)),
            pendingPlacedInterpretation: Int(sqlite3_column_int64(statement, 6))
        )
    }

    public static func constellationMessageRows(
        requiringCompletedEmbedding: Bool = true,
        storeURL: URL = defaultStoreURL()
    ) throws -> [MessageStoreConstellationMessageRow]? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let toRecipientsByMessagePK = try constellationRecipients(db, role: .to)
        let ccRecipientsByMessagePK = try constellationRecipients(db, role: .cc)
        let bccRecipientsByMessagePK = try constellationRecipients(db, role: .bcc)
        // All-non-From recipient addresses (To + Cc + Bcc, lowercased) —
        // separate from `toRecipientsByMessagePK` (which is the To-role
        // display list for the locked card header). The renderer's
        // `.people` major-correspondent check uses this broader set so
        // a sent message that CC'd a major correspondent stays vivid.
        let recipientAddressesByMessagePK = try frameParticipantAddresses(db)
        // `json_extract` runs in SQLite (3.9+, ships with macOS), so legacy
        // consumers can still read the two headline booleans as 0/1 ints.
        // UI snapshots also receive the raw verdict JSON and reply headers
        // below so they can resolve the shared open-attention state.
        // The `json_valid` guard is load-bearing: bare `json_extract` raises
        // `malformed JSON` on invalid input and aborts the cursor, which
        // would silently truncate the constellation if a single corrupt
        // verdict slipped past the writer. With the guard, invalid /
        // partially-written JSON resolves to NULL on the Swift side and
        // the row's headline flags fall back to "unknown" — same as a
        // message that hasn't been triaged yet. NULL input → NULL result
        // (json_valid(NULL) = NULL, CASE WHEN NULL THEN ... = NULL).
        let messageIdHeaderColumn = try tableHasColumn("ZMESSAGEIDHEADER", in: "ZMESSAGE", db: db)
            ? "m.ZMESSAGEIDHEADER"
            : "NULL"
        let inReplyToColumn = try tableHasColumn("ZINREPLYTO", in: "ZMESSAGE", db: db)
            ? "m.ZINREPLYTO"
            : "NULL"
        let referencesChainColumn = try tableHasColumn("ZREFERENCESCHAIN", in: "ZMESSAGE", db: db)
            ? "m.ZREFERENCESCHAIN"
            : "NULL"
        let isReadColumn = try tableHasColumn("ZISREAD", in: "ZMESSAGE", db: db)
            ? "COALESCE(m.ZISREAD, 0)"
            : "0"
        let liveDetectedAtColumn = try tableHasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE", db: db)
            ? "m.ZLIVEDETECTEDAT"
            : "NULL"
        let listIdColumn = try tableHasColumn("ZLISTID", in: "ZMESSAGE", db: db)
            ? "m.ZLISTID"
            : "NULL"
        let classificationColumn = try tableHasColumn(
            "ZMAILCLASSIFICATIONJSON",
            in: "ZMESSAGEANALYSIS",
            db: db
        ) ? "analysis.ZMAILCLASSIFICATIONJSON" : "NULL"
        let customCategoryKeysColumn = try tableHasColumn(
            "ZCUSTOMCATEGORYKEYSJSON",
            in: "ZMESSAGEANALYSIS",
            db: db
        ) ? "analysis.ZCUSTOMCATEGORYKEYSJSON" : "NULL"
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")
        let embeddingFilterSQL = requiringCompletedEmbedding
            ? "m.ZEMBEDDINGSTATUS = 'completed'"
            : "1 = 1"
        let sql = """
        SELECT
            m.Z_PK,
            m.ZID,
            COALESCE(m.ZACCOUNTID, a.ZID),
            m.ZMESSAGETYPE,
            m.ZEMBEDDINGSTATUS,
            m.ZSUBJECT,
            m.ZREPLIEDAT,
            m.ZISSENTBYUSER,
            COALESCE(m.ZFLAGGED, 0),
            m.ZHASATTACHMENTS,
            m.ZFROMADDRESS,
            m.ZFROMNAME,
            m.ZSENTAT,
            m.ZRECEIVEDAT,
            m.ZINGESTEDAT,
            m.ZBODYTEXTPATH,
            m.ZBODYHTMLPATH,
            analysis.ZDIMENSIONSJSON,
            analysis.ZBODYSUMMARY,
            \(classificationColumn),
            CASE WHEN json_valid(analysis.ZTRIAGEVERDICTJSON)
                 THEN json_extract(analysis.ZTRIAGEVERDICTJSON, '$.isActionable')
            END,
            CASE WHEN json_valid(analysis.ZTRIAGEVERDICTJSON)
                 THEN json_extract(analysis.ZTRIAGEVERDICTJSON, '$.requiresConfirmation')
            END,
            thread.ZID,
            \(messageIdHeaderColumn),
            \(inReplyToColumn),
            \(referencesChainColumn),
            analysis.ZTRIAGEVERDICTJSON,
            \(isReadColumn),
            \(liveDetectedAtColumn),
            \(listIdColumn),
            \(customCategoryKeysColumn),
            analysis.ZBODYSUMMARYINPUTFINGERPRINT
        FROM ZMESSAGE m
        LEFT JOIN ZACCOUNT a ON a.Z_PK = m.ZACCOUNT
        LEFT JOIN ZMESSAGEANALYSIS analysis ON analysis.Z_PK = m.ZANALYSIS
        LEFT JOIN ZMESSAGETHREAD thread ON thread.Z_PK = m.ZTHREAD
        WHERE \(embeddingFilterSQL)
          AND \(activeMessageSQL)
        ORDER BY m.Z_PK;
        """

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        var rows: [MessageStoreConstellationMessageRow] = []
        var stepResult: Int32 = SQLITE_OK
        while true {
            stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else { break }
            guard let messageId = blobData(statement, column: 1).flatMap(uuid(from:))?.uuidString else {
                continue
            }
            let messagePK = sqlite3_column_int64(statement, 0)
            let isActionable: Bool? = sqlite3_column_type(statement, 20) == SQLITE_NULL
                ? nil
                : sqlite3_column_int(statement, 20) != 0
            let requiresConfirmation: Bool? = sqlite3_column_type(statement, 21) == SQLITE_NULL
                ? nil
                : sqlite3_column_int(statement, 21) != 0
            let classificationJSON = text(statement, column: 19)
            rows.append(MessageStoreConstellationMessageRow(
                messageId: messageId,
                accountId: blobData(statement, column: 2).flatMap(uuid(from:)),
                threadId: blobData(statement, column: 22).flatMap(uuid(from:)),
                messageTypeRaw: text(statement, column: 3) ?? MessageType.unclassified.rawValue,
                embeddingStatusRaw: text(statement, column: 4) ?? ProcessingStatus.pending.rawValue,
                subject: text(statement, column: 5) ?? "",
                isRead: sqlite3_column_int(statement, 27) != 0,
                isReplied: sqlite3_column_type(statement, 6) != SQLITE_NULL,
                isSentByUser: sqlite3_column_int(statement, 7) != 0,
                flagged: sqlite3_column_int(statement, 8) != 0,
                hasAttachments: sqlite3_column_int(statement, 9) != 0,
                fromAddress: text(statement, column: 10) ?? "",
                fromName: text(statement, column: 11),
                sentAt: date(statement, column: 12),
                receivedAt: date(statement, column: 13),
                ingestedAt: date(statement, column: 14) ?? Date(timeIntervalSinceReferenceDate: 0),
                liveDetectedAt: date(statement, column: 28),
                bodyTextPath: text(statement, column: 15),
                bodyHtmlPath: text(statement, column: 16),
                dimensionsJSON: text(statement, column: 17),
                bodySummary: text(statement, column: 18),
                bodySummaryInputFingerprint: text(statement, column: 31),
                mailClassificationJSON: classificationJSON,
                customCategoryKeysJSON: text(statement, column: 30),
                triageIsActionable: isActionable,
                triageRequiresConfirmation: requiresConfirmation,
                triageVerdictJSON: text(statement, column: 26),
                messageIdHeader: text(statement, column: 23),
                inReplyTo: text(statement, column: 24),
                referencesChain: text(statement, column: 25),
                repliedAt: date(statement, column: 6),
                toRecipients: toRecipientsByMessagePK[messagePK] ?? [],
                ccRecipients: ccRecipientsByMessagePK[messagePK] ?? [],
                bccRecipients: bccRecipientsByMessagePK[messagePK] ?? [],
                recipientAddresses: recipientAddressesByMessagePK[messagePK] ?? [],
                listId: text(statement, column: 29)
            ))
        }
        // Don't silently truncate the constellation if the cursor aborted
        // mid-scan (SQLITE_ERROR / SQLITE_BUSY / SQLITE_CORRUPT). Caller
        // surfaces this as an empty/error snapshot rather than as a
        // partial-but-plausible scene.
        guard stepResult == SQLITE_DONE else {
            throw VectorStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    public static func frameEdgeRows(
        messageIds: [String],
        storeURL: URL = defaultStoreURL()
    ) throws -> [String: MessageStoreFrameEdgeRow]? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }
        let uniqueIds = Array(Set(messageIds)).sorted()
        guard !uniqueIds.isEmpty else { return [:] }

        let db = try openDatabase(storeURL: storeURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(db) }

        let participantAddressesByMessagePK = try frameParticipantAddresses(db)
        let isSentByUserExpression = try tableHasColumn("ZISSENTBYUSER", in: "ZMESSAGE", db: db)
            ? "COALESCE(m.ZISSENTBYUSER, 0)"
            : "0"
        let liveDetectedAtExpression = try tableHasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE", db: db)
            ? "m.ZLIVEDETECTEDAT"
            : "NULL"
        let messageTypeExpression = try tableHasColumn("ZMESSAGETYPE", in: "ZMESSAGE", db: db)
            ? "COALESCE(m.ZMESSAGETYPE, '\(MessageType.unclassified.rawValue)')"
            : "'\(MessageType.unclassified.rawValue)'"
        let hasAnalysisJoin = try tableHasColumn("ZANALYSIS", in: "ZMESSAGE", db: db)
            && tableHasColumn("Z_PK", in: "ZMESSAGEANALYSIS", db: db)
        let analysisJoin = hasAnalysisJoin
            ? "LEFT JOIN ZMESSAGEANALYSIS analysis ON analysis.Z_PK = m.ZANALYSIS"
            : ""
        let dimensionsExpression = hasAnalysisJoin ? "analysis.ZDIMENSIONSJSON" : "NULL"
        let hasClassificationColumn = hasAnalysisJoin
            ? try tableHasColumn(
                "ZMAILCLASSIFICATIONJSON",
                in: "ZMESSAGEANALYSIS",
                db: db
            )
            : false
        let classificationExpression = hasClassificationColumn
            ? "analysis.ZMAILCLASSIFICATIONJSON"
            : "NULL"
        let actionExpression = hasAnalysisJoin
            ? "CASE WHEN json_valid(analysis.ZTRIAGEVERDICTJSON) THEN json_extract(analysis.ZTRIAGEVERDICTJSON, '$.isActionable') END"
            : "NULL"
        let confirmationExpression = hasAnalysisJoin
            ? "CASE WHEN json_valid(analysis.ZTRIAGEVERDICTJSON) THEN json_extract(analysis.ZTRIAGEVERDICTJSON, '$.requiresConfirmation') END"
            : "NULL"
        let actionKindExpression = hasAnalysisJoin
            ? "CASE WHEN json_valid(analysis.ZTRIAGEVERDICTJSON) THEN json_extract(analysis.ZTRIAGEVERDICTJSON, '$.action.kind') END"
            : "NULL"
        let signalKindExpression = hasAnalysisJoin
            ? "CASE WHEN json_valid(analysis.ZTRIAGEVERDICTJSON) THEN json_extract(analysis.ZTRIAGEVERDICTJSON, '$.acknowledgement.signalKind') END"
            : "NULL"
        let activeMessageSQL = try activeMessageSQL(db: db, alias: "m")

        var out: [String: MessageStoreFrameEdgeRow] = [:]
        for chunkStart in stride(from: 0, to: uniqueIds.count, by: 500) {
            let chunk = Array(uniqueIds[chunkStart..<min(chunkStart + 500, uniqueIds.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
            SELECT
                m.Z_PK,
                m.ZID,
                thread.ZID,
                m.ZFROMADDRESS,
                COALESCE(m.ZRECEIVEDAT, m.ZSENTAT, m.ZINGESTEDAT),
                \(isSentByUserExpression),
                \(messageTypeExpression),
                \(dimensionsExpression),
                \(classificationExpression),
                \(actionExpression),
                \(confirmationExpression),
                \(actionKindExpression),
                \(signalKindExpression),
                \(liveDetectedAtExpression)
            FROM ZMESSAGE m
            LEFT JOIN ZMESSAGETHREAD thread ON thread.Z_PK = m.ZTHREAD
            \(analysisJoin)
            WHERE \(activeMessageSQL)
              AND m.ZID IN (\(placeholders));
            """
            let statement = try prepare(sql, db: db)
            defer { sqlite3_finalize(statement) }
            for (index, messageId) in chunk.enumerated() {
                guard let uuid = UUID(uuidString: messageId) else {
                    sqlite3_bind_null(statement, Int32(index + 1))
                    continue
                }
                try bindUUID(uuid, to: statement, index: Int32(index + 1))
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let messageId = blobData(statement, column: 1).flatMap(uuid(from:))?.uuidString else {
                    continue
                }
                let messagePK = sqlite3_column_int64(statement, 0)
                let isActionable: Bool? = sqlite3_column_type(statement, 9) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_int(statement, 9) != 0
                let requiresConfirmation: Bool? = sqlite3_column_type(statement, 10) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_int(statement, 10) != 0
                let classificationJSON = text(statement, column: 8)
                out[messageId] = MessageStoreFrameEdgeRow(
                    messageId: messageId,
                    threadId: blobData(statement, column: 2).flatMap(uuid(from:)),
                    fromAddress: text(statement, column: 3) ?? "",
                    date: date(statement, column: 4) ?? Date(timeIntervalSinceReferenceDate: 0),
                    isSentByUser: sqlite3_column_int(statement, 5) != 0,
                    liveDetectedAt: date(statement, column: 13),
                    participantAddresses: participantAddressesByMessagePK[messagePK] ?? [],
                    messageTypeRaw: text(statement, column: 6) ?? MessageType.unclassified.rawValue,
                    mailClassificationJSON: classificationJSON,
                    triageIsActionable: isActionable,
                    triageRequiresConfirmation: requiresConfirmation,
                    actionKindRaw: text(statement, column: 11),
                    signalKindRaw: text(statement, column: 12),
                    dimensionsJSON: text(statement, column: 7)
                )
            }
        }
        return out
    }

    private static func openDatabase(storeURL: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, flags, nil) == SQLITE_OK,
              let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw VectorStoreError.openFailed(message)
        }
        sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
        return opened
    }

    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let prepared = statement else {
            sqlite3_finalize(statement)
            throw VectorStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return prepared
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw VectorStoreError.prepareFailed(message)
        }
    }

    private static func tableHasColumn(
        _ column: String,
        in table: String,
        db: OpaquePointer
    ) throws -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, column: 1) == column {
                return true
            }
        }
        return false
    }

    /// SwiftData may open an older store before its optional Trash column is
    /// installed. Read-only hot paths therefore treat legacy schemas as fully
    /// active, while current schemas consistently require a null Trash date.
    private static func activeMessageSQL(
        db: OpaquePointer,
        alias: String? = nil
    ) throws -> String {
        guard try tableHasColumn("ZTRASHEDAT", in: "ZMESSAGE", db: db) else {
            return "1"
        }
        let prefix = alias.map { "\($0)." } ?? ""
        return "\(prefix)ZTRASHEDAT IS NULL"
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

    private static func uuidData(_ id: UUID) -> Data {
        var uuid = id.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    private static func bindUUID(_ uuid: UUID, to statement: OpaquePointer, index: Int32) throws {
        let data = uuidData(uuid)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                throw VectorStoreError.stepFailed("Missing UUID bytes")
            }
            sqlite3_bind_blob(statement, index, base, Int32(data.count), OHIA_SQLITE_TRANSIENT)
        }
    }

    private static func frameParticipantAddresses(_ db: OpaquePointer) throws -> [Int64: [String]] {
        guard try tableHasColumn("ZMESSAGE", in: "ZMESSAGEPARTICIPANT", db: db),
              try tableHasColumn("ZPARTICIPANT", in: "ZMESSAGEPARTICIPANT", db: db),
              try tableHasColumn("ZEMAILADDRESS", in: "ZPARTICIPANT", db: db) else {
            return [:]
        }

        let hasRoleColumn = try tableHasColumn("ZROLE", in: "ZMESSAGEPARTICIPANT", db: db)
        let rolePredicate = hasRoleColumn ? "WHERE mp.ZROLE != ?" : ""
        let sql = """
        SELECT
            mp.ZMESSAGE,
            p.ZEMAILADDRESS
        FROM ZMESSAGEPARTICIPANT mp
        JOIN ZPARTICIPANT p ON p.Z_PK = mp.ZPARTICIPANT
        \(rolePredicate)
        ORDER BY mp.ZMESSAGE, mp.Z_PK;
        """
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }
        if hasRoleColumn {
            sqlite3_bind_text(statement, 1, ParticipantRole.from.rawValue, -1, OHIA_SQLITE_TRANSIENT)
        }

        var out: [Int64: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messagePK = sqlite3_column_int64(statement, 0)
            guard let email = text(statement, column: 1)?.lowercased() else { continue }
            out[messagePK, default: []].append(email)
        }
        return out
    }

    private static func date(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }

    private static func constellationRecipients(
        _ db: OpaquePointer,
        role: ParticipantRole
    ) throws -> [Int64: [MessageStoreConstellationRecipient]] {
        let sql = """
        SELECT
            mp.ZMESSAGE,
            p.ZEMAILADDRESS,
            p.ZDISPLAYNAME
        FROM ZMESSAGEPARTICIPANT mp
        JOIN ZPARTICIPANT p ON p.Z_PK = mp.ZPARTICIPANT
        WHERE mp.ZROLE = ?
        ORDER BY mp.ZMESSAGE, mp.Z_PK;
        """
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, role.rawValue, -1, OHIA_SQLITE_TRANSIENT)

        var out: [Int64: [MessageStoreConstellationRecipient]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messagePK = sqlite3_column_int64(statement, 0)
            guard let email = text(statement, column: 1) else { continue }
            out[messagePK, default: []].append(MessageStoreConstellationRecipient(
                emailAddress: email,
                displayName: text(statement, column: 2)
            ))
        }
        return out
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, column) else {
            return nil
        }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}
