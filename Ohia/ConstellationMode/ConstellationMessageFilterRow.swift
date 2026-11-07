import Foundation
import OhiaCore
import OhiaML

public struct MessageFilterRow: Sendable {
    /// Owning account, or `nil` for messages without an attached account.
    /// Filter semantics: when
    /// `VectorFilter.accountIds != nil`, a row with `accountId == nil` is
    /// treated as "never matches" — `nil` here means "unattached", not
    /// "any account".
    public let accountId: UUID?
    /// Persistent `MessageThread.id` for the conversation this message belongs
    /// to. `nil` until `ThreadAssigner` populates the relationship at ingest —
    /// header-graph per message, plus the subject fallback reconciliation at
    /// ingestion milestones. Drives the People-lens within-band
    /// radial position: each hub's deepest thread hugs the planet's inner band
    /// edge, singletons float at the outer band edge.
    public let threadId: UUID?
    public let messageType: MessageType
    public let embeddingStatus: ProcessingStatus
    public let isRead: Bool
    public let isReplied: Bool
    public let isConfirmed: Bool
    public let isResolved: Bool
    public let isSentByUser: Bool
    public let flagged: Bool
    public let hasAttachments: Bool
    public let fromAddress: String
    public let fromName: String?
    /// Recipient addresses (To-role participants) — pre-lowercased so per-row
    /// correspondent matching doesn't allocate a new lowercased string.
    public let toAddresses: [String]
    /// Recipient display names (To-role participants) — pre-lowercased.
    public let toNames: [String]
    /// Recipient display names in original casing, index-aligned to `toAddresses`.
    public let toDisplayNames: [String]
    /// Cc recipient addresses — pre-lowercased and role-specific for display
    /// surfaces that need the full email header, not just People-lens matching.
    public let ccAddresses: [String]
    /// Cc recipient display names — pre-lowercased.
    public let ccNames: [String]
    /// Cc recipient display names in original casing, index-aligned to `ccAddresses`.
    public let ccDisplayNames: [String]
    /// Bcc recipient addresses — pre-lowercased and role-specific for display
    /// surfaces that need the full email header.
    public let bccAddresses: [String]
    /// Bcc recipient display names — pre-lowercased.
    public let bccNames: [String]
    /// Bcc recipient display names in original casing, index-aligned to `bccAddresses`.
    public let bccDisplayNames: [String]
    /// Every non-From participant address (To + Cc + Bcc) — pre-lowercased.
    /// Used by the renderer's `.people` major-correspondent check so a sent
    /// message that CC'd a major correspondent (without putting them on the
    /// To line) still reads as "near a major" — matching the layout-force
    /// path in `MessageGraphEdgeProvider.correspondentSignals`. Always a
    /// superset of `toAddresses` for messages with Cc/Bcc participants.
    public let recipientAddresses: [String]
    public var clusterId: Int64?
    /// Cluster-attachment strength for `clusterId`, in (0, 1]. Leiden
    /// attachment for Meaning-frame clusters; 1.0 for rows written before
    /// the weight column existed. `nil` when the row
    /// has no cluster. Drives the Meaning-lens metaball member halos.
    public var clusterWeight: Float?
    public var dimensions: MessageDimensions?
    /// Message subject (RFC 5322 `Subject`). Empty string for messages whose
    /// subject is missing — never `nil` so the hover never has to choose
    /// between "no subject yet" and "subject is the empty string".
    public let subject: String
    /// Timeline timestamp used by constellation surfaces. Incoming mail
    /// prefers the server/local received time; sent mail prefers the RFC Date
    /// (`sentAt`) so replies are ordered and labeled by when the user sent
    /// them, not by a mailbox sync/internal date.
    public let receivedAt: Date?
    /// Local persistence timestamp. Used by live UI affordances that need to
    /// distinguish newly-arrived rows from historical rows already present at
    /// scene load.
    public let ingestedAt: Date
    /// Live IMAP detection timestamp. Present only for live inbound rows that
    /// owe the unified arrival moment before becoming visible.
    public let liveDetectedAt: Date?
    /// On-disk path to the message body text. Read lazily by the lock readout
    /// when the user wants the full message, and by the hover summarizer when
    /// a generated `bodySummary` is missing.
    public let bodyTextPath: String?
    /// On-disk path to the original HTML body artifact when the message has
    /// one. Lock readout prefers this for richer display, falling back to the
    /// plain text body when absent.
    public let bodyHtmlPath: String?
    /// LLM-generated proportional summary, populated on demand when
    /// Constellation hover or lock requests one. `nil` until then; the hover
    /// shows an animated placeholder while a summary request is pending.
    public let bodySummary: String?
    /// Stable identity of the prepared language/glossary inputs that produced
    /// `bodySummary`. A missing value makes an existing summary stale.
    public let bodySummaryInputFingerprint: String?
    /// Canonical purpose classification document used when hover and lock
    /// requests reconstruct an already-known interpretation.
    public let mailClassificationJSON: String?
    /// Decoded exactly once when the value-type row is projected. Every UI
    /// consumer reads this projection instead of reparsing JSON in a render or
    /// filter loop.
    public let mailClassification: MailClassification?
    nonisolated public var purpose: MailPurpose? { mailClassification?.purpose }
    /// User-defined category keys (`custom.<slug>`) assigned to this
    /// message, already intersected with the live catalog by the loader so
    /// keys of removed categories never reach filtering or chips. A row
    /// with custom keys and no fixed categories is categorized — it does
    /// NOT fall back to `.unassigned`.
    public let customCategoryKeys: Set<String>
    /// Per-collection vector breakdown for this message — drives both the
    /// total "moons" count and the per-color dot pattern in the orbital
    /// glyph. Excludes `.style` (training-side artifacts).
    public let vectorBreakdown: MessageVectorCountBreakdown
    /// Distinct neighbor-message count above the configured similarity
    /// threshold (default 0.60). Drives the hover's "in orbit" count.
    public let neighborCount: Int
    /// Triage headline flags extracted from the verdict on summarize.
    /// `nil` for messages summarized before the slice-1–4 triage rollout
    /// (no verdict persisted yet) and for messages still pending summary.
    /// The toolbar's Headline section treats `nil` as "doesn't match
    /// either chip" so old un-triaged rows fall out of the filtered set
    /// when the user activates a Headline chip — matches the user's
    /// mental model that the chip is asking for a property the row
    /// either has or doesn't.
    public let isActionable: Bool?
    public let requiresConfirmation: Bool?
    /// Canonical RFC 2919 list identity for mailing-list mail; nil for
    /// direct mail and rows ingested before list parsing existed. Drives
    /// the Subscriptions ledger's scope-to-list filter.
    public let listId: String?

    /// All fields are positional in declaration order, but call sites MUST use
    /// argument labels to avoid swapping the two adjacent `Bool` pairs
    /// (`isRead`/`isReplied`, `flagged`/`hasAttachments`) or the adjacent
    /// `String?` field (`fromName`) with `clusterId`. Swift requires labels at
    /// the call site for all non-defaulted args, so this is enforced — the
    /// reminder is here for anyone who later refactors a call site to use
    /// positional spread (e.g. via a helper builder).
    nonisolated public init(
        accountId: UUID?,
        threadId: UUID? = nil,
        messageType: MessageType,
        embeddingStatus: ProcessingStatus = .pending,
        isRead: Bool,
        isReplied: Bool,
        isConfirmed: Bool = false,
        isResolved: Bool = false,
        isSentByUser: Bool,
        flagged: Bool,
        hasAttachments: Bool,
        fromAddress: String,
        fromName: String?,
        toAddresses: [String] = [],
        toNames: [String] = [],
        toDisplayNames: [String] = [],
        ccAddresses: [String] = [],
        ccNames: [String] = [],
        ccDisplayNames: [String] = [],
        bccAddresses: [String] = [],
        bccNames: [String] = [],
        bccDisplayNames: [String] = [],
        recipientAddresses: [String] = [],
        clusterId: Int64? = nil,
        clusterWeight: Float? = nil,
        dimensions: MessageDimensions? = nil,
        subject: String = "",
        receivedAt: Date? = nil,
        ingestedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        liveDetectedAt: Date? = nil,
        bodyTextPath: String? = nil,
        bodyHtmlPath: String? = nil,
        bodySummary: String? = nil,
        bodySummaryInputFingerprint: String? = nil,
        mailClassificationJSON: String? = nil,
        customCategoryKeys: Set<String> = [],
        vectorBreakdown: MessageVectorCountBreakdown = MessageVectorCountBreakdown(),
        neighborCount: Int = 0,
        isActionable: Bool? = nil,
        requiresConfirmation: Bool? = nil,
        listId: String? = nil
    ) {
        self.accountId = accountId
        self.threadId = threadId
        self.messageType = messageType
        self.embeddingStatus = embeddingStatus
        self.isRead = isRead
        self.isReplied = isReplied
        self.isConfirmed = isConfirmed
        self.isResolved = isResolved
        self.isSentByUser = isSentByUser
        self.flagged = flagged
        self.hasAttachments = hasAttachments
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.toAddresses = toAddresses
        self.toNames = toNames
        self.toDisplayNames = toDisplayNames
        self.ccAddresses = ccAddresses
        self.ccNames = ccNames
        self.ccDisplayNames = ccDisplayNames
        self.bccAddresses = bccAddresses
        self.bccNames = bccNames
        self.bccDisplayNames = bccDisplayNames
        // Default to the role-specific recipient union for callers that didn't pass an
        // explicit broader recipient set. This preserves the previous
        // behaviour for any caller that only knew about the To role —
        // they continue to get a To-only check, which is what they were
        // getting before — while new callers that do provide Cc/Bcc display
        // fields also get a correct broad recipient set.
        self.recipientAddresses = recipientAddresses.isEmpty
            ? toAddresses + ccAddresses + bccAddresses
            : recipientAddresses
        self.clusterId = clusterId
        self.clusterWeight = clusterWeight
        self.dimensions = dimensions
        self.subject = subject
        self.receivedAt = receivedAt
        self.ingestedAt = ingestedAt
        self.liveDetectedAt = liveDetectedAt
        self.bodyTextPath = bodyTextPath
        self.bodyHtmlPath = bodyHtmlPath
        self.bodySummary = SummaryTextSanitizer.cleaned(bodySummary)
        self.bodySummaryInputFingerprint = bodySummaryInputFingerprint
        self.mailClassificationJSON = mailClassificationJSON
        self.mailClassification = MailClassificationJSON.decode(mailClassificationJSON)
        self.customCategoryKeys = Set(CustomCategoryKeysJSON.canonicalKeys(customCategoryKeys))
        self.vectorBreakdown = vectorBreakdown
        self.neighborCount = neighborCount
        self.isActionable = isActionable
        self.requiresConfirmation = requiresConfirmation
        self.listId = listId
    }

    nonisolated static func currentReplyNeededFromRawTriage(
        _ rawIsActionable: Bool?,
        isReplied: Bool,
        isSentByUser: Bool
    ) -> Bool? {
        guard rawIsActionable == true else { return rawIsActionable }
        return (isReplied || isSentByUser) ? false : true
    }

    nonisolated static func currentConfirmationNeededFromRawTriage(
        _ rawRequiresConfirmation: Bool?,
        isReplied: Bool,
        isSentByUser: Bool
    ) -> Bool? {
        guard rawRequiresConfirmation == true else { return rawRequiresConfirmation }
        return (isReplied || isSentByUser) ? false : true
    }
}
