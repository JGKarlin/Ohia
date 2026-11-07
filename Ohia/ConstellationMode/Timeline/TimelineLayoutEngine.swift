import Foundation
import CoreGraphics
import OhiaCore
import OhiaML

/// Pure, `Sendable` snapshot builder. Runs off-main (`Task.detached`)
/// against pre-fetched value-type inputs — no `ModelContext` / `Message` /
/// `MessageThread` references cross the actor boundary.
///
/// The engine groups the input messages into threads + orphans, builds
/// chapters, derives clip / event / attachment geometry, and emits a
/// `TimelineLayoutSnapshot` whose lanes are now keyed by
/// `TimelineMultitrackRow` (sender, receiver, attachments, Purpose,
/// thread, account, status). Context and Delivery never become Purpose groups.
public enum TimelineLayoutEngine {

    public struct Input: Sendable {
        public var signature: TimelineLayoutSignature
        public var viewportRange: ClosedRange<Date>
        public var pixelsPerDay: Double
        public var bracketedRange: ClosedRange<Date>?
        public var messages: [MessageRow]
        public var threads: [ThreadRow]
        public var attachments: [AttachmentRow]
        public var aiAnnotations: [TimelineLayoutSnapshot.AIAnnotation]

        public nonisolated init(
            signature: TimelineLayoutSignature,
            viewportRange: ClosedRange<Date>,
            pixelsPerDay: Double,
            bracketedRange: ClosedRange<Date>?,
            messages: [MessageRow],
            threads: [ThreadRow],
            attachments: [AttachmentRow],
            aiAnnotations: [TimelineLayoutSnapshot.AIAnnotation]
        ) {
            self.signature = signature
            self.viewportRange = viewportRange
            self.pixelsPerDay = pixelsPerDay
            self.bracketedRange = bracketedRange
            self.messages = messages
            self.threads = threads
            self.attachments = attachments
            self.aiAnnotations = aiAnnotations
        }
    }

    public struct MessageRow: Sendable, Hashable {
        public let id: UUID
        public let threadID: UUID?
        public let date: Date
        public let purposeState: TimelinePurposeState
        public let customCategories: [TimelineLayoutSnapshot.CustomCategoryTag]
        public let subject: String
        public let isSentByUser: Bool
        public let hasAttachments: Bool
        public let fromAddress: String?
        public let fromName: String?
        public let recipients: [TimelineLayoutSnapshot.Recipient]
        public let accountID: UUID?
        public let accountName: String
        public let accountColorIndex: Int
        public let isRead: Bool
        public let isListIgnoreEligible: Bool
        public let isActionable: Bool
        public let isInComposerQueue: Bool
        public let requiresConfirmation: Bool
        public let isReplied: Bool
        public let isConfirmed: Bool
        public let hasDeadline: Bool
        public let deadlineText: String?
        public let isResolved: Bool
        public let isFlagged: Bool
        public let isRevivedAfterInactiveGap: Bool
        public let sharedEvidenceKinds: Set<MessageSharedEvidenceKind>
        public nonisolated init(
            id: UUID,
            threadID: UUID?,
            date: Date,
            purposeState: TimelinePurposeState,
            customCategories: [TimelineLayoutSnapshot.CustomCategoryTag] = [],
            subject: String,
            isSentByUser: Bool,
            hasAttachments: Bool,
            fromAddress: String?,
            fromName: String?,
            recipients: [TimelineLayoutSnapshot.Recipient],
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
            sharedEvidenceKinds: Set<MessageSharedEvidenceKind> = []
        ) {
            self.id = id
            self.threadID = threadID
            self.date = date
            self.purposeState = purposeState
            self.customCategories = customCategories
            self.subject = subject
            self.isSentByUser = isSentByUser
            self.hasAttachments = hasAttachments
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
        }
    }

    public struct ThreadRow: Sendable, Hashable {
        public let id: UUID
        public let subjectRoot: String
        public let participantCount: Int
        public nonisolated init(id: UUID, subjectRoot: String, participantCount: Int) {
            self.id = id
            self.subjectRoot = subjectRoot
            self.participantCount = participantCount
        }
    }

    public struct AttachmentRow: Sendable, Hashable {
        public let id: UUID
        public let parentMessageID: UUID
        public let kind: TimelineAttachmentKind
        public let name: String
        public nonisolated init(id: UUID, parentMessageID: UUID, kind: TimelineAttachmentKind, name: String) {
            self.id = id
            self.parentMessageID = parentMessageID
            self.kind = kind
            self.name = name
        }
    }

    public nonisolated static func snapshot(input: Input) -> TimelineLayoutSnapshot {
        let zoomTier = TimelineZoomTier.tier(forPixelsPerDay: input.pixelsPerDay)
        // Fixed, deterministic row order — `TimelineMultitrackRow.allCases`
        // mirrors enum declaration order (sender, receiver, attachments,
        // category, thread, account, status). The gutter solos/mutes
        // narrow what's drawn; the snapshot itself always carries the full
        // set.
        let laneOrder = TimelineMultitrackRow.allCases

        // Sort messages by date ascending — the canonical ordering used by
        // chapters, events, and the playhead resolver.
        let messagesByDate = input.messages.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        // Build chapters: one per thread, one per orphan.
        var messagesByThread: [UUID: [MessageRow]] = [:]
        var orphans: [MessageRow] = []
        for msg in messagesByDate {
            if let threadID = msg.threadID {
                messagesByThread[threadID, default: []].append(msg)
            } else {
                orphans.append(msg)
            }
        }

        let threadsByID: [UUID: ThreadRow] = Dictionary(
            uniqueKeysWithValues: input.threads.map { ($0.id, $0) }
        )

        var chapters: [TimelineChapter] = []
        for (threadID, msgs) in messagesByThread {
            guard let first = msgs.first, let last = msgs.last else { continue }
            let primary = primaryPurpose(of: msgs)
            let row = threadsByID[threadID]
            chapters.append(
                TimelineChapter(
                    id: threadID,
                    kind: .thread(threadID: threadID),
                    start: first.date,
                    end: last.date,
                    title: row?.subjectRoot ?? first.subject,
                    messageIDs: msgs.map(\.id),
                    participantCount: row?.participantCount ?? 1,
                    primaryPurpose: primary
                )
            )
        }
        for msg in orphans {
            chapters.append(
                TimelineChapter(
                    id: msg.id,
                    kind: .orphan(messageID: msg.id),
                    start: msg.date,
                    end: msg.date,
                    title: msg.subject.isEmpty ? "(no subject)" : msg.subject,
                    messageIDs: [msg.id],
                    participantCount: 1,
                    primaryPurpose: msg.purposeState
                )
            )
        }
        chapters.sort { (lhs, rhs) in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // Drop empty chapters (defensive — should already be removed by
        // upstream filter intersection).
        chapters = chapters.filter { $0.messageIDs.isEmpty == false }

        // Reverse-index message → chapter for event-tick stamping.
        var chapterByMessageID: [UUID: UUID] = [:]
        for chapter in chapters {
            for messageID in chapter.messageIDs {
                chapterByMessageID[messageID] = chapter.id
            }
        }

        // Clips (per thread). Orphan messages don't get a thread clip —
        // they appear only as the focused-email tick on the .thread row
        // when scrubbed to.
        var clips: [TimelineLayoutSnapshot.ClipGeometry] = []
        for chapter in chapters {
            switch chapter.kind {
            case .thread(let threadID):
                clips.append(
                    TimelineLayoutSnapshot.ClipGeometry(
                        threadID: threadID,
                        chapterID: chapter.id,
                        purposeState: chapter.primaryPurpose,
                        startDate: chapter.start,
                        endDate: chapter.end,
                        messageCount: chapter.messageIDs.count,
                        participantCount: chapter.participantCount,
                        subject: chapter.title
                    )
                )
            case .orphan:
                continue
            }
        }

        // Event ticks per message — the contextual ticks that render
        // across every row at the message's x-position.
        var events: [TimelineLayoutSnapshot.EventTick] = []
        events.reserveCapacity(messagesByDate.count)
        for msg in messagesByDate {
            guard let chapterID = chapterByMessageID[msg.id] else { continue }
            events.append(
                TimelineLayoutSnapshot.EventTick(
                    messageID: msg.id,
                    threadID: msg.threadID,
                    chapterID: chapterID,
                    purposeState: msg.purposeState,
                    date: msg.date,
                    isSentByUser: msg.isSentByUser,
                    hasAttachments: msg.hasAttachments
                )
            )
        }

        // Attachments → marks, keyed by parent message.
        let dateByMessageID: [UUID: Date] = Dictionary(
            uniqueKeysWithValues: messagesByDate.map { ($0.id, $0.date) }
        )
        let purposeByMessageID: [UUID: TimelinePurposeState] = Dictionary(
            uniqueKeysWithValues: messagesByDate.map { ($0.id, $0.purposeState) }
        )

        var attachmentMarks: [TimelineLayoutSnapshot.AttachmentMark] = []
        var attachmentsByMessage: [UUID: [UUID]] = [:]
        for attachment in input.attachments {
            guard let date = dateByMessageID[attachment.parentMessageID],
                  let purposeState = purposeByMessageID[attachment.parentMessageID] else { continue }
            attachmentMarks.append(
                TimelineLayoutSnapshot.AttachmentMark(
                    attachmentID: attachment.id,
                    parentMessageID: attachment.parentMessageID,
                    purposeState: purposeState,
                    kind: attachment.kind,
                    date: date,
                    name: attachment.name
                )
            )
            attachmentsByMessage[attachment.parentMessageID, default: []].append(attachment.id)
        }

        // Correspondent chips — top-N by message count in the window.
        let correspondents = makeCorrespondentChips(messages: messagesByDate)

        // Playhead-resolver index. Sorted ascending by date.
        let sortedEntries: [TimelinePlayheadResolver.MessageIndexEntry] = messagesByDate.map {
            TimelinePlayheadResolver.MessageIndexEntry(id: $0.id, date: $0.date)
        }

        // Complete send-direction lookup over the eligible set (orphans
        // included) so the minimap can split its density histogram into
        // received vs sent without re-deriving direction from `events`,
        // which drops chapter-less messages.
        let directionByMessageID: [UUID: Bool] = Dictionary(
            uniqueKeysWithValues: messagesByDate.map { ($0.id, $0.isSentByUser) }
        )

        // MessageMetadata lookup for the focused-email chip rows.
        var messageMetadata: [UUID: TimelineLayoutSnapshot.MessageMeta] = [:]
        for msg in messagesByDate {
            guard let chapterID = chapterByMessageID[msg.id] else { continue }
            messageMetadata[msg.id] = TimelineLayoutSnapshot.MessageMeta(
                messageID: msg.id,
                threadID: msg.threadID,
                chapterID: chapterID,
                date: msg.date,
                purposeState: msg.purposeState,
                customCategories: msg.customCategories,
                subject: msg.subject,
                isSentByUser: msg.isSentByUser,
                fromAddress: msg.fromAddress?.lowercased() ?? "",
                fromName: msg.fromName ?? "",
                recipients: msg.recipients,
                accountID: msg.accountID,
                accountName: msg.accountName,
                accountColorIndex: msg.accountColorIndex,
                isRead: msg.isRead,
                isListIgnoreEligible: msg.isListIgnoreEligible,
                isActionable: msg.isActionable,
                isInComposerQueue: msg.isInComposerQueue,
                requiresConfirmation: msg.requiresConfirmation,
                isReplied: msg.isReplied,
                isConfirmed: msg.isConfirmed,
                hasDeadline: msg.hasDeadline,
                deadlineText: msg.deadlineText,
                isResolved: msg.isResolved,
                isFlagged: msg.isFlagged,
                isRevivedAfterInactiveGap: msg.isRevivedAfterInactiveGap,
                sharedEvidenceKinds: msg.sharedEvidenceKinds,
                attachmentIDs: attachmentsByMessage[msg.id] ?? []
            )
        }

        return TimelineLayoutSnapshot(
            builtAt: Date(),
            signature: input.signature,
            viewportRange: input.viewportRange,
            pixelsPerDay: input.pixelsPerDay,
            zoomTier: zoomTier,
            laneOrder: laneOrder,
            clips: clips,
            events: events,
            attachmentMarks: attachmentMarks,
            correspondents: correspondents,
            aiAnnotations: input.aiAnnotations,
            chapters: chapters,
            sortedEligibleEntries: sortedEntries,
            messageDateLookup: dateByMessageID,
            messageDirectionLookup: directionByMessageID,
            messageMetadata: messageMetadata
        )
    }

    private nonisolated static func primaryPurpose(of msgs: [MessageRow]) -> TimelinePurposeState {
        var counts: [TimelinePurposeState: Int] = [:]
        for message in msgs { counts[message.purposeState, default: 0] += 1 }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return purposeSortIndex(lhs.key) > purposeSortIndex(rhs.key)
        }?.key ?? .pending
    }

    private nonisolated static func purposeSortIndex(_ state: TimelinePurposeState) -> Int {
        switch state {
        case .resolved(let purpose): MailPurpose.allCases.firstIndex(of: purpose) ?? .max
        case .uncertain: MailPurpose.allCases.count
        case .pending: MailPurpose.allCases.count + 1
        }
    }

    private nonisolated static func makeCorrespondentChips(
        messages: [MessageRow]
    ) -> [TimelineLayoutSnapshot.CorrespondentChip] {
        struct Aggregate {
            var displayName: String
            var count: Int
            var first: Date
            var last: Date
        }
        var byEmail: [String: Aggregate] = [:]
        for msg in messages {
            guard let email = msg.fromAddress, email.isEmpty == false else { continue }
            let lower = email.lowercased()
            let name = msg.fromName ?? email
            if var existing = byEmail[lower] {
                existing.count += 1
                if msg.date < existing.first { existing.first = msg.date }
                if msg.date > existing.last { existing.last = msg.date }
                if existing.displayName.isEmpty { existing.displayName = name }
                byEmail[lower] = existing
            } else {
                byEmail[lower] = Aggregate(
                    displayName: name,
                    count: 1,
                    first: msg.date,
                    last: msg.date
                )
            }
        }
        let chips = byEmail
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.key < rhs.key
            }
            .prefix(48)
            .map { entry in
                TimelineLayoutSnapshot.CorrespondentChip(
                    email: entry.key,
                    displayName: entry.value.displayName,
                    messageCount: entry.value.count,
                    firstSeen: entry.value.first,
                    lastSeen: entry.value.last
                )
            }
        return Array(chips)
    }
}
