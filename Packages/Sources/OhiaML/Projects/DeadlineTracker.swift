import Foundation

/// Which section of the Deadlines tracker an entry belongs to.
public enum DeadlineStatus: String, Codable, Sendable, Equatable {
    /// The deadline day has not yet fully passed and the user has not resolved it.
    case upcoming
    /// The deadline passed without being resolved (overdue).
    case past
    /// The user marked the deadline done. Wins over the date-derived state.
    case resolved
}

/// One message that carries a resolved, dated deadline. The app layer produces
/// these by scanning stored analysis and resolving each surface phrase; the
/// pure tracker below collapses them per thread and classifies them.
public struct DeadlineObservation: Sendable, Equatable {
    public let messageID: UUID
    public let threadID: UUID?
    public let accountID: UUID?
    /// The message's own date — also the reference the deadline resolved against.
    public let messageDate: Date
    public let subject: String
    /// Non-user participants on this message (the user is filtered at source).
    public let participants: [ProjectParticipant]
    /// Total emails in this message's thread within the current scope (1 for a
    /// standalone message). Same for every observation sharing a thread.
    public let threadMessageCount: Int
    public let deadline: ResolvedDeadlineDate
    public let deadlineType: String
    public let surfaceText: String
    public let evidenceText: String
    /// Whether the message is marked resolved (shared with the Projects lens).
    public let isResolvedByUser: Bool
    public let isSentByUser: Bool
    public let isFlagged: Bool
    public let isActionable: Bool
    public let requiresConfirmation: Bool
    public let isReplied: Bool
    public let isConfirmed: Bool
    public let isInComposerQueue: Bool

    public init(
        messageID: UUID,
        threadID: UUID?,
        accountID: UUID?,
        messageDate: Date,
        subject: String,
        participants: [ProjectParticipant],
        threadMessageCount: Int,
        deadline: ResolvedDeadlineDate,
        deadlineType: String,
        surfaceText: String,
        evidenceText: String,
        isResolvedByUser: Bool,
        isSentByUser: Bool = false,
        isFlagged: Bool = false,
        isActionable: Bool = false,
        requiresConfirmation: Bool = false,
        isReplied: Bool = false,
        isConfirmed: Bool = false,
        isInComposerQueue: Bool = false
    ) {
        self.messageID = messageID
        self.threadID = threadID
        self.accountID = accountID
        self.messageDate = messageDate
        self.subject = subject
        self.participants = participants
        self.threadMessageCount = max(1, threadMessageCount)
        self.deadline = deadline
        self.deadlineType = deadlineType
        self.surfaceText = surfaceText
        self.evidenceText = evidenceText
        self.isResolvedByUser = isResolvedByUser
        self.isSentByUser = isSentByUser
        self.isFlagged = isFlagged
        self.isActionable = isActionable
        self.requiresConfirmation = requiresConfirmation
        self.isReplied = isReplied
        self.isConfirmed = isConfirmed
        self.isInComposerQueue = isInComposerQueue
    }
}

/// A user-authored scheduling override imported from Calendar.app. The source
/// email evidence is deliberately left intact and can be restored at any time.
public struct DeadlineDateOverride: Sendable, Equatable {
    public let date: Date
    public let granularity: DeadlineDateGranularity

    public init(date: Date, granularity: DeadlineDateGranularity) {
        self.date = date
        self.granularity = granularity
    }
}

/// A tracked deadline: one thread's (or one standalone email's) single deadline.
public struct DeadlineEntry: Identifiable, Sendable, Equatable {
    /// Stable across rebuilds: the thread id, or the message id for standalone.
    public let id: String
    /// The message whose deadline this entry shows (the most-recent mention).
    public let representativeMessageID: UUID
    public let threadID: UUID?
    public let accountID: UUID?
    public let title: String
    /// Non-user correspondents across the collapsed thread, volume-ordered.
    public let correspondents: [ProjectParticipant]
    public let messageCount: Int
    public let deadlineDate: Date
    public let granularity: DeadlineDateGranularity
    public let deadlineType: String
    public let surfaceText: String
    public let evidenceText: String
    /// Most recent message date across the collapsed thread — drives the
    /// timeline's activity anchor and secondary sorts.
    public let lastActivityAt: Date
    public let isResolvedByUser: Bool
    public let isSentByUser: Bool
    public let isFlagged: Bool
    public let isActionable: Bool
    public let requiresConfirmation: Bool
    public let isReplied: Bool
    public let isConfirmed: Bool
    public let isInComposerQueue: Bool
    public let status: DeadlineStatus

    /// A hard deadline is the loudest; used for accenting / interruption level.
    public var isHard: Bool { deadlineType.lowercased() == "hard" }
}

/// The classified, sorted deadline sections.
public struct DeadlineTrackerSnapshot: Sendable, Equatable {
    /// Not yet due, unresolved — soonest first.
    public let upcoming: [DeadlineEntry]
    /// Overdue, unresolved — most-recently-passed first.
    public let past: [DeadlineEntry]
    /// Resolved by the user — most recent deadline first.
    public let resolved: [DeadlineEntry]

    public init(upcoming: [DeadlineEntry], past: [DeadlineEntry], resolved: [DeadlineEntry]) {
        self.upcoming = upcoming
        self.past = past
        self.resolved = resolved
    }

    public static let empty = DeadlineTrackerSnapshot(upcoming: [], past: [], resolved: [])

    /// Every entry across the three sections — the calendar plots all of them.
    public var allEntries: [DeadlineEntry] { upcoming + past + resolved }

    public var isEmpty: Bool { upcoming.isEmpty && past.isEmpty && resolved.isEmpty }

    public func entry(id: String) -> DeadlineEntry? {
        allEntries.first { $0.id == id }
    }
}

/// Collapses per-message deadline observations into one entry per thread
/// (standalone emails stay their own entry), applying "most recent mention
/// wins" and classifying each into Upcoming / Past / Resolved.
public enum DeadlineTracker {

    public static func build(
        observations: [DeadlineObservation],
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        dateOverrides: [String: DeadlineDateOverride] = [:]
    ) -> DeadlineTrackerSnapshot {
        guard !observations.isEmpty else { return .empty }

        var groups: [String: [DeadlineObservation]] = [:]
        for observation in observations {
            groups[groupKey(for: observation), default: []].append(observation)
        }

        let entries = groups.map { key, members in
            entry(
                id: key,
                members: members,
                now: now,
                calendar: calendar,
                dateOverride: dateOverrides[key]
            )
        }

        var upcoming: [DeadlineEntry] = []
        var past: [DeadlineEntry] = []
        var resolved: [DeadlineEntry] = []
        for entry in entries {
            switch entry.status {
            case .upcoming: upcoming.append(entry)
            case .past: past.append(entry)
            case .resolved: resolved.append(entry)
            }
        }

        upcoming.sort { ($0.deadlineDate, $0.id) < ($1.deadlineDate, $1.id) }
        past.sort { ($0.deadlineDate, $0.id) > ($1.deadlineDate, $1.id) }
        resolved.sort { ($0.deadlineDate, $0.id) > ($1.deadlineDate, $1.id) }

        return DeadlineTrackerSnapshot(upcoming: upcoming, past: past, resolved: resolved)
    }

    private static func groupKey(for observation: DeadlineObservation) -> String {
        if let threadID = observation.threadID {
            return "thread-\(threadID.uuidString)"
        }
        return "msg-\(observation.messageID.uuidString)"
    }

    private static func entry(
        id: String,
        members: [DeadlineObservation],
        now: Date,
        calendar: Calendar,
        dateOverride: DeadlineDateOverride?
    ) -> DeadlineEntry {
        // Most recent mention wins: the latest-dated message that carries a
        // deadline defines the entry's date/type/surface (later emails
        // supersede — revisions, extensions). Tie-break on message id so the
        // choice is deterministic.
        let representative = members.max {
            ($0.messageDate, $0.messageID.uuidString) < ($1.messageDate, $1.messageID.uuidString)
        }!

        let correspondents = mergedCorrespondents(members)
        let lastActivityAt = members.map(\.messageDate).max() ?? representative.messageDate
        let effectiveDeadline = dateOverride.map {
            ResolvedDeadlineDate(date: $0.date, granularity: $0.granularity)
        } ?? representative.deadline

        let status: DeadlineStatus
        if representative.isResolvedByUser {
            status = .resolved
        } else if effectiveDeadline.overdueThreshold(calendar: calendar) <= now {
            status = .past
        } else {
            status = .upcoming
        }

        return DeadlineEntry(
            id: id,
            representativeMessageID: representative.messageID,
            threadID: representative.threadID,
            accountID: representative.accountID,
            title: representative.subject,
            correspondents: correspondents,
            messageCount: representative.threadMessageCount,
            deadlineDate: effectiveDeadline.date,
            granularity: effectiveDeadline.granularity,
            deadlineType: representative.deadlineType,
            surfaceText: representative.surfaceText,
            evidenceText: representative.evidenceText,
            lastActivityAt: lastActivityAt,
            isResolvedByUser: representative.isResolvedByUser,
            isSentByUser: representative.isSentByUser,
            isFlagged: representative.isFlagged,
            isActionable: representative.isActionable,
            requiresConfirmation: representative.requiresConfirmation,
            isReplied: representative.isReplied,
            isConfirmed: representative.isConfirmed,
            isInComposerQueue: representative.isInComposerQueue,
            status: status
        )
    }

    /// Union of non-user correspondents across the collapsed thread, ordered by
    /// how often each appears (then address, for stability).
    private static func mergedCorrespondents(_ members: [DeadlineObservation]) -> [ProjectParticipant] {
        struct Tally { var participant: ProjectParticipant; var count: Int }
        var byEmail: [String: Tally] = [:]
        for member in members {
            for participant in member.participants {
                let key = participant.email.lowercased()
                guard !key.isEmpty else { continue }
                if var existing = byEmail[key] {
                    existing.count += 1
                    if existing.participant.displayName == nil, participant.displayName != nil {
                        existing.participant = participant
                    }
                    byEmail[key] = existing
                } else {
                    byEmail[key] = Tally(participant: participant, count: 1)
                }
            }
        }
        return byEmail.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.participant.email < $1.participant.email
            }
            .map(\.participant)
    }
}
