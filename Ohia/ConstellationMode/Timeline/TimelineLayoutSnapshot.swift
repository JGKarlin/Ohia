import Foundation
import CoreGraphics
import OhiaCore
import OhiaML

/// Timeline's explicit Purpose presentation state. A missing classification is
/// still pending work, while a completed classification without a resolved
/// Purpose is uncertain. Neither state is collapsed into the real `.other`
/// Purpose.
public enum TimelinePurposeState: Sendable, Equatable, Hashable {
    case resolved(MailPurpose)
    case uncertain
    case pending

    public nonisolated init(classification: MailClassification?) {
        guard let classification else {
            self = .pending
            return
        }
        if let purpose = classification.purpose {
            self = .resolved(purpose)
        } else {
            self = .uncertain
        }
    }

    public nonisolated var purpose: MailPurpose? {
        guard case .resolved(let purpose) = self else { return nil }
        return purpose
    }

    public nonisolated var displayLabel: String {
        switch self {
        case .resolved(let purpose): purpose.displayLabel
        case .uncertain: "Uncertain"
        case .pending: "Pending"
        }
    }

    public nonisolated var systemImageName: String {
        switch self {
        case .resolved(let purpose): purpose.systemImageName
        case .uncertain: "questionmark.circle"
        case .pending: "tray"
        }
    }
}

/// Value-type output of `TimelineLayoutEngine.snapshot(...)`. Carries every
/// laid-out element the Canvas, hit-tester, and resolvers need. Pre-sorted
/// and pre-bucketed indexes are included so per-drag work is O(log n).
///
/// Constructed off-main; consumed on-main. No reference types (no
/// `Message` / `MessageThread` / `ModelContext` leaks).
public struct TimelineLayoutSnapshot: Sendable, Equatable {
    public let builtAt: Date
    public let signature: TimelineLayoutSignature
    public let viewportRange: ClosedRange<Date>
    public let pixelsPerDay: Double
    public let zoomTier: TimelineZoomTier

    /// The fixed semantic rows of the multitrack. Stable across snapshots;
    /// `TimelineMultitrackRow.allCases` in canonical order.
    public let laneOrder: [TimelineMultitrackRow]
    public let clips: [ClipGeometry]
    public let events: [EventTick]
    public let attachmentMarks: [AttachmentMark]
    public let correspondents: [CorrespondentChip]
    public let aiAnnotations: [AIAnnotation]

    public let chapters: [TimelineChapter]
    public let sortedEligibleEntries: [TimelinePlayheadResolver.MessageIndexEntry]
    public let messageDateLookup: [UUID: Date]

    /// Per-message send-direction lookup, complete over the eligible set
    /// (orphan/chapter-less messages included, unlike `events`). `true` ==
    /// sent by the account owner. Drives the minimap's diverging density
    /// histogram (received above the midline, sent below).
    public let messageDirectionLookup: [UUID: Bool]

    /// Per-message lookup: everything the focused-email chip rows need.
    public let messageMetadata: [UUID: MessageMeta]

    public struct ClipGeometry: Sendable, Equatable, Hashable {
        public let threadID: UUID
        public let chapterID: UUID
        public let purposeState: TimelinePurposeState
        public let startDate: Date
        public let endDate: Date
        public let messageCount: Int
        public let participantCount: Int
        public let subject: String
        public nonisolated init(
            threadID: UUID,
            chapterID: UUID,
            purposeState: TimelinePurposeState,
            startDate: Date,
            endDate: Date,
            messageCount: Int,
            participantCount: Int,
            subject: String
        ) {
            self.threadID = threadID
            self.chapterID = chapterID
            self.purposeState = purposeState
            self.startDate = startDate
            self.endDate = endDate
            self.messageCount = messageCount
            self.participantCount = participantCount
            self.subject = subject
        }
    }

    public struct EventTick: Sendable, Equatable, Hashable {
        public let messageID: UUID
        public let threadID: UUID?
        public let chapterID: UUID
        public let purposeState: TimelinePurposeState
        public let date: Date
        public let isSentByUser: Bool
        public let hasAttachments: Bool
        public nonisolated init(
            messageID: UUID,
            threadID: UUID?,
            chapterID: UUID,
            purposeState: TimelinePurposeState,
            date: Date,
            isSentByUser: Bool,
            hasAttachments: Bool
        ) {
            self.messageID = messageID
            self.threadID = threadID
            self.chapterID = chapterID
            self.purposeState = purposeState
            self.date = date
            self.isSentByUser = isSentByUser
            self.hasAttachments = hasAttachments
        }
    }

    public struct AttachmentMark: Sendable, Equatable, Hashable {
        public let attachmentID: UUID
        public let parentMessageID: UUID
        public let purposeState: TimelinePurposeState
        public let kind: TimelineAttachmentKind
        public let date: Date
        public let name: String
        public nonisolated init(
            attachmentID: UUID,
            parentMessageID: UUID,
            purposeState: TimelinePurposeState,
            kind: TimelineAttachmentKind,
            date: Date,
            name: String
        ) {
            self.attachmentID = attachmentID
            self.parentMessageID = parentMessageID
            self.purposeState = purposeState
            self.kind = kind
            self.date = date
            self.name = name
        }
    }

    public struct CorrespondentChip: Sendable, Equatable, Hashable {
        public let email: String
        public let displayName: String
        public let messageCount: Int
        public let firstSeen: Date
        public let lastSeen: Date
        public nonisolated init(
            email: String,
            displayName: String,
            messageCount: Int,
            firstSeen: Date,
            lastSeen: Date
        ) {
            self.email = email
            self.displayName = displayName
            self.messageCount = messageCount
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
        }
    }

    public struct AIAnnotation: Sendable, Equatable, Hashable {
        public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
            case actionItems
            case unresolved
            case deadlines
            case contradictions
            case duplicates
        }
        public let kind: Kind
        public let messageID: UUID
        public let date: Date
        public let purposeState: TimelinePurposeState
        public nonisolated init(
            kind: Kind,
            messageID: UUID,
            date: Date,
            purposeState: TimelinePurposeState
        ) {
            self.kind = kind
            self.messageID = messageID
            self.date = date
            self.purposeState = purposeState
        }
    }

    public struct Recipient: Sendable, Equatable, Hashable {
        public enum Role: String, Sendable, Codable, Hashable { case to, cc, bcc }
        public let email: String
        public let displayName: String
        public let role: Role
        public nonisolated init(email: String, displayName: String, role: Role) {
            self.email = email
            self.displayName = displayName
            self.role = role
        }
    }

    /// User-defined category assignment carried independently from Purpose so
    /// the multitrack row can render custom chips with their display names.
    public struct CustomCategoryTag: Sendable, Equatable, Hashable {
        public let key: String
        public let displayName: String

        public nonisolated init(key: String, displayName: String) {
            self.key = key
            self.displayName = displayName
        }
    }

    public struct MessageMeta: Sendable, Equatable, Hashable {
        public let messageID: UUID
        public let threadID: UUID?
        public let chapterID: UUID
        public let date: Date
        public let purposeState: TimelinePurposeState
        public let customCategories: [CustomCategoryTag]
        public let subject: String
        public let isSentByUser: Bool
        public let fromAddress: String
        public let fromName: String
        public let recipients: [Recipient]
        public let accountID: UUID?
        public let accountName: String
        /// Index into `AccountColorPalette.all` for this message's account.
        /// Drives the per-row context-tick color so the dashes inherit the
        /// account's stellar/nebular hue.
        public let accountColorIndex: Int
        public let isRead: Bool
        /// Whether this message can seed a list-scoped ignore rule.
        public let isListIgnoreEligible: Bool
        /// Shared attention state: true only while this message still needs a reply.
        public let isActionable: Bool
        /// True when this needs-reply message is already in the Composer queue.
        public let isInComposerQueue: Bool
        /// Shared attention state: true only while this message still needs confirmation.
        public let requiresConfirmation: Bool
        /// True once reply evidence or a manual mark has cleared the reply obligation.
        public let isReplied: Bool
        /// True once the user manually marked the message confirmed.
        public let isConfirmed: Bool
        /// True when structured interpretation extracted at least one concrete deadline.
        public let hasDeadline: Bool
        /// Surface text for the first extracted deadline, when available.
        public let deadlineText: String?
        /// True when the user has dismissed the message from shared attention surfaces.
        public let isResolved: Bool
        /// Mirror of the message's IMAP `\Flagged` state.
        public let isFlagged: Bool
        public let isRevivedAfterInactiveGap: Bool
        public let sharedEvidenceKinds: Set<MessageSharedEvidenceKind>
        public let attachmentIDs: [UUID]
        public nonisolated init(
            messageID: UUID,
            threadID: UUID?,
            chapterID: UUID,
            date: Date,
            purposeState: TimelinePurposeState,
            customCategories: [CustomCategoryTag] = [],
            subject: String,
            isSentByUser: Bool,
            fromAddress: String,
            fromName: String,
            recipients: [Recipient],
            accountID: UUID?,
            accountName: String,
            accountColorIndex: Int,
            isRead: Bool,
            isListIgnoreEligible: Bool = false,
            isActionable: Bool = false,
            isInComposerQueue: Bool = false,
            requiresConfirmation: Bool = false,
            isReplied: Bool = false,
            isConfirmed: Bool = false,
            hasDeadline: Bool = false,
            deadlineText: String? = nil,
            isResolved: Bool = false,
            isFlagged: Bool = false,
            isRevivedAfterInactiveGap: Bool = false,
            sharedEvidenceKinds: Set<MessageSharedEvidenceKind> = [],
            attachmentIDs: [UUID]
        ) {
            self.messageID = messageID
            self.threadID = threadID
            self.chapterID = chapterID
            self.date = date
            self.purposeState = purposeState
            self.customCategories = customCategories
            self.subject = subject
            self.isSentByUser = isSentByUser
            self.fromAddress = fromAddress
            self.fromName = fromName
            self.recipients = recipients
            self.accountID = accountID
            self.accountName = accountName
            self.accountColorIndex = accountColorIndex
            self.isRead = isRead
            self.isListIgnoreEligible = isListIgnoreEligible
            self.isActionable = isActionable
            self.isInComposerQueue = isInComposerQueue
            self.requiresConfirmation = requiresConfirmation
            self.isReplied = isReplied
            self.isConfirmed = isConfirmed
            self.hasDeadline = hasDeadline
            let trimmedDeadline = deadlineText?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.deadlineText = hasDeadline && trimmedDeadline?.isEmpty == false ? trimmedDeadline : nil
            self.isResolved = isResolved
            self.isFlagged = isFlagged
            self.isRevivedAfterInactiveGap = isRevivedAfterInactiveGap
            self.sharedEvidenceKinds = sharedEvidenceKinds
            self.attachmentIDs = attachmentIDs
        }

        var statusDescriptor: MessageStatusDescriptor {
            MessageStatusDescriptor(
                isSentByUser: isSentByUser,
                isRead: isRead,
                isReplied: isReplied,
                isConfirmed: isConfirmed,
                isResolved: isResolved,
                needsReply: isActionable,
                needsConfirmation: requiresConfirmation,
                hasDeadline: hasDeadline,
                deadlineText: deadlineText,
                isFlagged: isFlagged,
                isRevivedAfterInactiveGap: isRevivedAfterInactiveGap,
                sharedEvidenceKinds: sharedEvidenceKinds
            )
        }
    }

    public nonisolated init(
        builtAt: Date,
        signature: TimelineLayoutSignature,
        viewportRange: ClosedRange<Date>,
        pixelsPerDay: Double,
        zoomTier: TimelineZoomTier,
        laneOrder: [TimelineMultitrackRow],
        clips: [ClipGeometry],
        events: [EventTick],
        attachmentMarks: [AttachmentMark],
        correspondents: [CorrespondentChip],
        aiAnnotations: [AIAnnotation],
        chapters: [TimelineChapter],
        sortedEligibleEntries: [TimelinePlayheadResolver.MessageIndexEntry],
        messageDateLookup: [UUID: Date],
        messageDirectionLookup: [UUID: Bool],
        messageMetadata: [UUID: MessageMeta]
    ) {
        self.builtAt = builtAt
        self.signature = signature
        self.viewportRange = viewportRange
        self.pixelsPerDay = pixelsPerDay
        self.zoomTier = zoomTier
        self.laneOrder = laneOrder
        self.clips = clips
        self.events = events
        self.attachmentMarks = attachmentMarks
        self.correspondents = correspondents
        self.aiAnnotations = aiAnnotations
        self.chapters = chapters
        self.sortedEligibleEntries = sortedEligibleEntries
        self.messageDateLookup = messageDateLookup
        self.messageDirectionLookup = messageDirectionLookup
        self.messageMetadata = messageMetadata
    }
}

/// LoD ladder tier — coarse summary of the current zoom level. Drives which
/// layers render and at what density.
public enum TimelineZoomTier: Int, Sendable, CaseIterable, Comparable {
    case yearPlus      = 0  // <= 0.05 px/day
    case months        = 1  // 0.05 – 2.0
    case weeks         = 2  // 2.0 – 24.0
    case daysAndHours  = 3  // >= 24.0

    public nonisolated static func < (lhs: TimelineZoomTier, rhs: TimelineZoomTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public nonisolated static func tier(forPixelsPerDay ppd: Double) -> TimelineZoomTier {
        if ppd <= 0.05 { return .yearPlus }
        if ppd <= 2.0 { return .months }
        if ppd <= 24.0 { return .weeks }
        return .daysAndHours
    }
}

/// Cache-key fingerprint for the `(filter, window, bracket, search)` tuple
/// that gates a snapshot. Equality + hash drive `TimelineLayoutSnapshotCache`.
public struct TimelineLayoutSignature: Sendable, Hashable {
    /// Optional sets so the signature differentiates "filter is nil
    /// (all on by default)" from "filter is an explicit empty set
    /// (nothing matches)". Collapsing both to `Set()` previously
    /// confused the snapshot cache when the user turned off their
    /// only account — the signature didn't change, the cache served
    /// the stale snapshot, and the email pane kept rendering the old
    /// message even though the filter excluded everything.
    public let accountIDs: Set<UUID>?
    public let correspondentEmails: Set<String>
    public let purposes: Set<MailPurpose>?
    public let statusFingerprint: String
    public let presetWindow: ClosedRange<Date>?
    public let bracketedWindow: ClosedRange<Date>?
    public let searchTokens: [String]
    public let zoomTier: TimelineZoomTier

    public nonisolated init(
        accountIDs: Set<UUID>?,
        correspondentEmails: Set<String>,
        purposes: Set<MailPurpose>?,
        statusFingerprint: String,
        presetWindow: ClosedRange<Date>?,
        bracketedWindow: ClosedRange<Date>?,
        searchTokens: [String],
        zoomTier: TimelineZoomTier
    ) {
        self.accountIDs = accountIDs
        self.correspondentEmails = correspondentEmails
        self.purposes = purposes
        self.statusFingerprint = statusFingerprint
        self.presetWindow = presetWindow
        self.bracketedWindow = bracketedWindow
        self.searchTokens = searchTokens
        self.zoomTier = zoomTier
    }

    public nonisolated static func == (
        lhs: TimelineLayoutSignature,
        rhs: TimelineLayoutSignature
    ) -> Bool {
        lhs.accountIDs == rhs.accountIDs
            && lhs.correspondentEmails == rhs.correspondentEmails
            && lhs.purposes == rhs.purposes
            && lhs.statusFingerprint == rhs.statusFingerprint
            && lhs.presetWindow == rhs.presetWindow
            && lhs.bracketedWindow == rhs.bracketedWindow
            && lhs.searchTokens == rhs.searchTokens
            && lhs.zoomTier == rhs.zoomTier
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(accountIDs)
        hasher.combine(correspondentEmails)
        hasher.combine(purposes)
        hasher.combine(statusFingerprint)
        hasher.combine(presetWindow)
        hasher.combine(bracketedWindow)
        hasher.combine(searchTokens)
        hasher.combine(zoomTier)
    }
}
