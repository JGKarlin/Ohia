import Foundation
import SwiftData

@Model
public final class Message {
    public var id: UUID
    /// Scalar account key for high-volume mailbox work. Keep this in sync with
    /// `account` when creating or repairing rows; hot paths should prefer this
    /// over walking the SwiftData relationship.
    public var accountID: UUID?
    @Relationship(deleteRule: .nullify)
    public var account: Account?
    public var subject: String
    public var sentAt: Date?
    public var receivedAt: Date?
    public var ingestedAt: Date
    public var fromAddress: String
    public var fromName: String?
    /// Normalized addresses from the inbound RFC 5322 `Reply-To` header.
    /// Nil means the header was absent or unusable, so reply composition falls
    /// back to `fromAddress`. Optional for lightweight migration; reset and
    /// re-ingest populates rows created before this field existed.
    public var replyToAddressesJSON: String?
    public var contentHash: String?
    public var messageIdHeader: String?
    public var inReplyTo: String?

    // Threading / reply tracking (added for SMTP send plumbing).
    // Note: the incoming RFC 5322 Message-ID lives in the pre-existing
    // `messageIdHeader` field above — we reuse it rather than adding a
    // parallel field. The send-plumbing spec initially named this
    // `messageIDHeader`; all references have been normalized to the
    // existing lowercase-d spelling.
    public var requiresReply: Bool = true
    /// User override for Composer queue membership (`ComposerQueueOverride`
    /// raw string). `nil` means automatic: actionable live-inbound mail that
    /// still requires a reply. Raw-string storage (not a Codable enum) so
    /// SwiftData lightweight migration and `#Predicate` translation never
    /// see a custom enum type; optional so existing rows migrate.
    public var composerQueueOverrideRaw: String? = nil
    public var repliedAt: Date?
    public var regenerationFeedback: String?
    public var referencesChain: String?
    public var languageDetected: String?
    public var hasAttachments: Bool
    /// User-flagged ("starred"). Optional Bool to remain safe under
    /// SwiftData lightweight migration: existing rows reach this field
    /// with `nil`, which `flaggedOrFalse` collapses to false. Adding a
    /// non-Optional with a default would crash existing stores per the
    /// project's SwiftData migration rule (see CLAUDE.md).
    public var flagged: Bool?
    /// Read/unread state, mirroring the IMAP \Seen flag where the
    /// underlying transport is IMAP. Optional Bool to remain safe under
    /// SwiftData lightweight migration; existing rows reach this with
    /// nil, which `isReadOrFalse` collapses to false (treated as unread).
    /// Seeded at ingest from IMAP `\Seen`. Toggles in the UI propagate back
    /// to the source server through `MailboxMutation` jobs.
    public var isRead: Bool?
    /// Best-known moment this row became or was observed as read. Optional
    /// for SwiftData lightweight migration; rows imported before this field
    /// use surface-specific fallback aging until re-ingested or changed.
    public var readAt: Date?
    /// Ordinary Delete retains the complete message and its semantic artifacts
    /// while removing it from active product surfaces. Optional for SwiftData
    /// lightweight migration: `nil` is the pre-existing active state.
    public var trashedAt: Date? = nil
    public var isSentByUser: Bool
    public var rawPath: String?
    public var bodyTextPath: String?
    public var bodyHtmlPath: String?
    /// Version of the deterministic translation-glossary evidence scan that
    /// last completed for this authored message. Optional for lightweight
    /// migration; `nil` rows are picked up by the bounded refresh worker.
    public var translationGlossaryEvidenceVersion: String? = nil
    public var embeddingStatus: ProcessingStatus
    public var trainingStatus: ProcessingStatus
    public var messageType: MessageType

    // Live/new-mail pipeline telemetry. These are optional so existing stores
    // migrate safely; `ingestedAt` above remains the ingest timestamp.
    public var liveDetectedAt: Date? = nil
    public var classifiedAt: Date? = nil
    public var embeddedAt: Date? = nil
    public var placedAt: Date? = nil
    /// Triage stamped this live inbound message as requiring complete reply
    /// preparation before its first presentation. Optional for lightweight
    /// migration; nil preserves the historical non-gated behavior.
    public var replyPreparationRequiredAt: Date?
    /// The complete reply preparation was durably published. This remains set
    /// after first presentation as evidence that the gate was satisfied.
    public var replyPreparationReadyAt: Date?

    // IMAP origin tracking.
    public var imapFolderPath: String? = nil
    public var imapUID: UInt32 = 0

    // Mailing-list identity (RFC 2919 / 2369 / 8058). Parsed from headers
    // at ingestion; all optional so existing stores lightweight-migrate.
    // Rows ingested before these fields existed read nil — a reset →
    // re-ingest populates history.
    /// Canonical list identity: the angle-bracket token of `List-Id`,
    /// lowercased (e.g. "announce.lists.example.com").
    public var listId: String? = nil
    /// The `List-Id` display phrase when present ("Campus Announcements").
    public var listDisplayName: String? = nil
    /// First `mailto:` target from `List-Unsubscribe`, address only.
    public var listUnsubscribeMailto: String? = nil
    /// First `http(s):` target from `List-Unsubscribe`.
    public var listUnsubscribeURL: String? = nil
    /// True when `List-Unsubscribe-Post: List-Unsubscribe=One-Click`
    /// accompanied an HTTPS target (RFC 8058).
    public var listSupportsOneClickUnsubscribe: Bool? = nil
    /// Deterministic ingestion fact from `List-ID`, `List-Unsubscribe`,
    /// bulk/list `Precedence`, or a non-`no` `Auto-Submitted` header. This is
    /// an internal safety/routing signal, not a model-generated category.
    public var isAutomatedOrBulk: Bool? = nil

    public var thread: MessageThread?

    @Relationship(deleteRule: .cascade, inverse: \MessageParticipant.message)
    public var participants: [MessageParticipant] = []

    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    public var attachments: [Attachment] = []

    @Relationship(deleteRule: .cascade, inverse: \MessageAnalysis.message)
    public var analysis: MessageAnalysis?

    @Relationship(deleteRule: .nullify, inverse: \SentTrainingEvidence.sourceMessage)
    public var sentTrainingEvidence: SentTrainingEvidence?

    /// Reply-flavor Drafts only. `.userCompose` Drafts have `Draft.message ==
    /// nil` and are unreachable through this inverse — they survive Message
    /// deletion by design.
    @Relationship(deleteRule: .cascade, inverse: \Draft.message)
    public var draft: Draft?

    /// Complete reply preparation created before first presentation or after a
    /// visible manual Needs Reply action, and adopted only on Composer entry.
    /// Optional for lightweight migration of existing Message rows.
    @Relationship(deleteRule: .cascade, inverse: \ReplySourcePreparation.message)
    public var replySourcePreparation: ReplySourcePreparation? = nil

    @Relationship(deleteRule: .cascade, inverse: \MessageCategory.message)
    public var categories: [MessageCategory] = []

    @Relationship(deleteRule: .cascade, inverse: \SemanticTagObservation.message)
    public var semanticTagObservations: [SemanticTagObservation] = []

    @Relationship(deleteRule: .cascade, inverse: \MessageSemanticTagMembership.message)
    public var semanticTagMemberships: [MessageSemanticTagMembership] = []

    public init(
        fromAddress: String,
        subject: String,
        ingestedAt: Date = Date()
    ) {
        self.id = UUID()
        self.accountID = nil
        self.fromAddress = fromAddress
        self.subject = subject
        self.ingestedAt = ingestedAt
        self.hasAttachments = false
        self.flagged = false
        self.isSentByUser = false
        self.embeddingStatus = .pending
        self.trainingStatus = .pending
        self.messageType = .unclassified
    }
}

public extension Message {
    /// True only for Ohia's retained user-Trash lifecycle. This is independent
    /// of the provider folder path, which intentionally stays at the original
    /// source coordinates until the asynchronous mailbox move reconciles.
    var isTrashed: Bool {
        trashedAt != nil
    }

    /// Date used by vector-layer time filters and placement ordering. Prefer
    /// the provider received timestamp, then fall back to the RFC
    /// `Date` header. Ranged Moments filters should not fall back to ingestion
    /// or placement time.
    var vectorTimeFilterDate: Date? {
        receivedAt ?? sentAt
    }

    /// Date used by background pipeline queues when choosing the next message
    /// to process. Prefer the server/local received timestamp so mail that
    /// arrives after a long seed starts jumps ahead of older historical mail,
    /// then fall back to the RFC `Date` header and ingestion time.
    var pipelineOrderingDate: Date {
        receivedAt ?? sentAt ?? ingestedAt
    }

    static func newestPipelineFirst(_ lhs: Message, _ rhs: Message) -> Bool {
        let lhsDate = lhs.pipelineOrderingDate
        let rhsDate = rhs.pipelineOrderingDate
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        if lhs.ingestedAt != rhs.ingestedAt {
            return lhs.ingestedAt > rhs.ingestedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// `flagged` collapsed to a non-Optional Bool. Existing pre-migration
    /// rows reach this property with `nil` (treated as false). Hot paths
    /// reading the flagged signal should prefer this over the raw field.
    var flaggedOrFalse: Bool {
        flagged ?? false
    }

    /// `isRead` collapsed to a non-Optional Bool. Existing pre-migration
    /// rows and rows ingested before \Seen seeding reach this with nil,
    /// which is treated as unread. Read-state UI should prefer this over
    /// the raw field.
    var isReadOrFalse: Bool {
        isRead ?? false
    }

    /// Keep read-state transitions and their timestamp coupled. Passing `nil`
    /// preserves the unknown pre-migration state and clears the timestamp.
    func applyReadState(_ value: Bool?, observedAt: Date = Date()) {
        let existingReadAt = readAt
        let wasRead = isRead == true
        isRead = value
        if value == true {
            readAt = wasRead ? (existingReadAt ?? observedAt) : observedAt
        } else {
            readAt = nil
        }
    }

    /// Only messages detected by the live inbound path are eligible for the
    /// expensive action/confirmation triage pass. Historical IMAP
    /// backfill rows still get classification and semantic labels, but should
    /// not create new obligations merely because they were imported.
    var isLiveInboundTriageEligible: Bool {
        liveDetectedAt != nil && !isSentByUser
    }

    /// How long newly arrived Needs Reply mail may stay off every surface
    /// while its reply is prepared (a preparation normally takes about a
    /// minute). Past it the email appears and the reply keeps preparing.
    static let replyPreparationPresentationHold: TimeInterval = 120

    /// When newly arrived Needs Reply mail appears even though its reply is
    /// not prepared yet.
    var replyPreparationPresentationDeadline: Date? {
        (liveDetectedAt ?? replyPreparationRequiredAt)?
            .addingTimeInterval(Self.replyPreparationPresentationHold)
    }

    /// Newly ingested Needs Reply mail stays absent from product surfaces until
    /// its complete preparation publishes readiness, for at most
    /// `replyPreparationPresentationHold` after it arrived. Already placed
    /// messages remain visible when the user manually adds Needs Reply.
    func blocksFirstPresentationForReplyPreparation(at now: Date = Date()) -> Bool {
        guard placedAt == nil, replyPreparationRequiredAt != nil, replyPreparationReadyAt == nil,
              let deadline = replyPreparationPresentationDeadline else { return false }
        return now < deadline
    }

    /// `composerQueueOverrideRaw` decoded. Unknown raw values read as nil
    /// (automatic) so a downgrade never crashes membership computation.
    var composerQueueOverride: ComposerQueueOverride? {
        get { composerQueueOverrideRaw.flatMap(ComposerQueueOverride.init(rawValue:)) }
        set { composerQueueOverrideRaw = newValue?.rawValue }
    }

    /// The triage-derived automatic Composer queue candidate state, before
    /// the user's queue-intake preference is applied.
    var isAutomaticComposerQueueCandidate: Bool {
        messageType == .actionable && isLiveInboundTriageEligible && requiresReply
    }

    /// Whether this message carries its conversation's Composer reply queue
    /// item, before draft-status gating (a sent or rejected draft still
    /// removes the row). Single source of truth shared by the queue UI, the
    /// node context menu's Composer queue state, and the draft-generation
    /// intake pass. A conversation is one queue item, replying to its newest
    /// email that itself qualifies — an unanswered automatic candidate, or an
    /// explicit include (see `composerConversationQueueResolution`); mail
    /// outside a thread keeps the email's own decision:
    ///   - explicit user exclude → never in the queue,
    ///   - explicit user include → in the queue (inbound mail only),
    ///   - no override → actionable live-inbound mail that still requires
    ///     a reply, only when Settings allows automatic triage queueing.
    var isComposerQueueEligible: Bool {
        isComposerQueueEligible(
            automaticTriageQueueingEnabled: ComposerQueueIntakePreference.automaticTriageQueueingEnabled()
        )
    }

    func isComposerQueueEligible(automaticTriageQueueingEnabled: Bool) -> Bool {
        let decision = composerQueueEmailDecision(
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        )
        guard thread != nil else { return decision == .qualifies }
        // Cheap per-email checks first: only an email that qualifies itself,
        // or one still holding its conversation's unsent reply Draft, can
        // carry the item, so every other email skips the thread scan.
        guard decision == .qualifies
            || (decision == nil && !isTrashed && !isSentByUser && holdsUnsentReplyDraft) else {
            return false
        }
        return composerConversationQueueResolution(
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        ).item?.id == id
    }

    /// This email's own Composer queue decision, before its conversation is
    /// considered. Nil when it decides nothing: sent or trashed mail, and mail
    /// with no override that is not an automatic candidate (or automatic
    /// triage queueing is off).
    func composerQueueEmailDecision(
        automaticTriageQueueingEnabled: Bool
    ) -> ComposerQueueEmailDecision? {
        guard !isTrashed, !isSentByUser else { return nil }
        switch composerQueueOverride {
        case .exclude:
            return .excluded
        case .include:
            return .qualifies
        case nil:
            return automaticTriageQueueingEnabled && isAutomaticComposerQueueCandidate
                ? .qualifies : nil
        }
    }

    /// True while this email holds its conversation's unsent reply Draft:
    /// one still being written, or confirmed and waiting in the outbox. A
    /// reply sent from the Composer stamps `repliedAt`, so the Draft history
    /// of answered mail costs no read. The relationship is only tested for
    /// presence — following it into a Draft another context just deleted
    /// would fault a missing row — and the status comes from a store-keyed
    /// fetch, which only returns rows that exist.
    var holdsUnsentReplyDraft: Bool {
        guard repliedAt == nil, draft != nil else { return false }
        guard let modelContext else { return draft.map { Self.isUnsentReply($0.status) } ?? false }
        let messageID = id
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.message?.id == messageID }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first).map { Self.isUnsentReply($0.status) } ?? false
    }

    /// True once the Composer sent its reply to this email: an explicit
    /// include is then spent, and stays only as a record. The send stamps
    /// `repliedAt`, so unanswered mail costs no read; the status comes from a
    /// store-keyed fetch for the same reason as `holdsUnsentReplyDraft`.
    var hasSentComposerReply: Bool {
        guard repliedAt != nil, draft != nil else { return false }
        guard let modelContext else { return draft?.status == .sent }
        let messageID = id
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.message?.id == messageID }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first)?.status == .sent
    }

    /// A reply Draft that still belongs to its conversation: being written,
    /// or confirmed and not yet sent.
    static func isUnsentReply(_ status: DraftStatus) -> Bool {
        status == .pending || status == .confirmed
    }

    /// The stored members of this email's conversation, itself included, each
    /// once. Mail outside a thread is its own conversation.
    var composerConversationMembers: [Message] {
        guard let thread else { return [self] }
        var seen: Set<UUID> = [id]
        var members: [Message] = [self]
        for member in thread.messages where seen.insert(member.id).inserted {
            members.append(member)
        }
        return members
    }

    /// When the author last replied in a conversation: the newest of their
    /// sent emails (never an unsent Ohia Composer mailbox draft). Inbound mail
    /// dated before it is answered — the same ordering the attention
    /// resolver's reply clearance uses.
    static func composerConversationLatestReplyDate(in members: [Message]) -> Date? {
        members.lazy
            .filter { $0.isSentByUser && !isOhiaComposerMailboxDraftMessageID($0.messageIdHeader) }
            .map(\.pipelineOrderingDate)
            .max()
    }

    /// Resolves this email's conversation to its one Composer queue item.
    ///
    /// The reply targets the newest inbound email that makes a queue
    /// decision: an automatic Needs Reply candidate or an explicit exclusion
    /// after the author's latest sent email, or an explicit include at any
    /// date ("Send to Composer" also follows up on an answered email) until
    /// the Composer reply it asked for is sent (`hasSentComposerReply`). When
    /// that email qualifies — an include, or an automatic candidate — it is
    /// the target; when it is explicitly excluded ("No Reply Needed" on the
    /// conversation's item) the conversation has no item until a newer
    /// qualifying email arrives. An exclusion on an earlier email only stops
    /// that email from counting, and a later email that decides nothing (a
    /// CC'd "Thanks", an FYI) stays thread context.
    ///
    /// The item is the target, except while another email still holds the
    /// conversation's unsent reply Draft (`holdsUnsentReplyDraft`): that email
    /// keeps the item until the Draft moves to the target
    /// (`ComposerThreadChangeReconciler`) or its send lands, so the
    /// conversation is never two items and the Draft never strands. The
    /// holder may be older (a newer qualifying email arrived) or newer (the
    /// newer email it moved to was trashed or no longer qualifies).
    func composerConversationQueueResolution(
        automaticTriageQueueingEnabled: Bool
    ) -> ComposerConversationQueueResolution {
        guard thread != nil else {
            let target = composerQueueEmailDecision(
                automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
            ) == .qualifies ? self : nil
            return ComposerConversationQueueResolution(target: target, item: target)
        }
        let members = composerConversationMembers
        let latestReply = Self.composerConversationLatestReplyDate(in: members)
        var newest: Message?
        var newestDecision: ComposerQueueEmailDecision?
        for member in members {
            guard let decision = member.composerQueueEmailDecision(
                automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
            ) else { continue }
            // An explicit include ("Send to Composer") counts at any date —
            // the author may follow up on an email they already answered —
            // until the Composer reply it asked for is sent. Automatic
            // candidates and exclusions count only while unanswered.
            if member.composerQueueOverride == .include {
                if member.hasSentComposerReply { continue }
            } else if let latestReply, latestReply > member.pipelineOrderingDate {
                continue
            }
            if let current = newest, !Self.newestPipelineFirst(member, current) { continue }
            newest = member
            newestDecision = decision
        }
        guard let target = newest, newestDecision == .qualifies else {
            return ComposerConversationQueueResolution(target: nil, item: nil)
        }
        guard !target.holdsUnsentReplyDraft else {
            return ComposerConversationQueueResolution(target: target, item: target)
        }
        var holder: Message?
        for member in members
        where member.id != target.id
            && !member.isTrashed
            && !member.isSentByUser
            && member.composerQueueOverride != .exclude
            && member.holdsUnsentReplyDraft {
            if let current = holder, !Self.newestPipelineFirst(member, current) { continue }
            holder = member
        }
        return ComposerConversationQueueResolution(target: target, item: holder ?? target)
    }
}

/// One email's own Composer queue decision (`Message.composerQueueEmailDecision`).
public enum ComposerQueueEmailDecision: Sendable, Equatable {
    /// Explicitly included, or an automatic Needs Reply candidate.
    case qualifies
    /// Explicitly excluded ("No Reply Needed").
    case excluded
}

/// A conversation's Composer queue resolution
/// (`Message.composerConversationQueueResolution`).
public struct ComposerConversationQueueResolution {
    /// The email the conversation's reply targets, when the conversation has
    /// a queue item at all.
    public let target: Message?
    /// The email that carries the queue item: the target, or the email still
    /// holding the conversation's unsent reply Draft.
    public let item: Message?
}

/// Explicit user decision about a message's Composer queue membership.
/// Stored on `Message.composerQueueOverrideRaw`.
public enum ComposerQueueOverride: String, Codable, Sendable {
    /// The user sent the message to the Composer queue.
    case include
    /// The user marked it "No Reply Needed" / removed it from the queue.
    case exclude
}
