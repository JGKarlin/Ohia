import Foundation
import SwiftData

/// Persistent threading service. Three entry points:
///
/// - `assignOnIngest(message:context:)` — called by `IngestionOrchestrator`
///   after a new `Message` row is inserted. Uses cheap header-only matching
///   against the existing DB to find or grow a `MessageThread`. The
///   normalized-subject + participant-overlap fallback is deliberately
///   skipped here (it would require a much wider candidate fetch) — the
///   `reconcileOrphansBySubject` pass picks up the subject-fallback links.
///
/// - `reconcileOrphansBySubject(context:)` — reconciliation pass over
///   currently-unthreaded rows, invoked at an IMAP ingestion milestone. It
///   first retries the
///   cheap header graph against existing rows, then applies the subject +
///   participant-overlap fallback to the remaining orphans, so the fallback
///   links land at ingestion time rather than via a boot pass.
///
/// - `groupIntoThreads(_:)` — pure batch function that takes an array of
///   `Message` rows and returns the union-find component mapping
///   (message UUID → root UUID). Used by `reconcileOrphansBySubject`
///   and by test fixtures that derive thread groupings without SwiftData.
///
/// Algorithm (shared between the two entry points):
/// - Union-find with path compression over the input message set.
/// - Header graph: a pair is unioned when one message's `Message-ID`
///   appears in the other's `In-Reply-To` / `References`, or when two
///   messages reference the same parent token.
/// - Subject fallback (batch only): messages whose normalized subject
///   matches AND whose participant sets overlap get unioned even if
///   their header chain is broken — this catches replies whose
///   envelope headers were mangled by intermediary mail servers.
/// - Determinism: the union-find root for a component is the
///   component's lexicographically-lowest message UUID, so re-runs
///   produce identical thread IDs for the same input.
/// `ThreadAssigner` itself is not actor-isolated. The static functions only
/// touch their `ModelContext` argument, so they inherit the caller's isolation
/// rather than imposing their own.
public enum ThreadAssigner {

    // MARK: - Per-message hook (ingest path)

    /// Find or grow a `MessageThread` for a freshly-inserted message.
    /// Header-only matching: extracts Message-ID + References tokens
    /// from the new message, fetches sibling candidates whose headers
    /// touch those tokens, and assigns thread membership via union-find
    /// over `[message] + candidates`.
    ///
    /// Three outcomes for the new message:
    /// - No header-linked candidates → leaves `message.thread == nil`
    ///   (orphan). `reconcileOrphansBySubject` may attach it later via
    ///   the subject fallback at the next ingestion milestone.
    /// - Candidates exist, at least one already in a thread → joins
    ///   that thread; any other linked candidates without a thread
    ///   get pulled in too.
    /// - Candidates exist, none threaded yet → creates a new
    ///   `MessageThread` covering all linked members.
    ///
    /// Idempotent: callers may invoke this multiple times for the
    /// same message; an already-threaded message still has its thread's
    /// header-linked reply state reconciled.
    public static func assignOnIngest(
        message: Message,
        context: ModelContext
    ) {
        if let thread = message.thread {
            applyReplyClearance(in: thread.messages, context: context)
            return
        }

        let selfMessageIDTokens = messageIDTokens(from: message.messageIdHeader)
        let selfReferencedTokens = referencedMessageIDTokens(for: message)
        let selfMessageIDSearchTokens = messageIDSearchTokens(from: message.messageIdHeader)
        let selfReferencedSearchTokens = referencedMessageIDSearchTokens(for: message)
        if selfMessageIDTokens.isEmpty, selfReferencedTokens.isEmpty {
            return
        }

        // Fetch sibling candidates via predicate-driven token lookup. Stored
        // header fields keep their raw RFC-5322 form (e.g. `<id@example.com>`),
        // so we search with original-case tokens first and filter matches by the
        // normalized `Message-ID` key.
        var candidates: [UUID: Message] = [:]
        for token in selfReferencedSearchTokens {
            for parent in fetchByHeaderToken(token, field: .messageIDHeader, context: context) {
                guard parent.id != message.id else { continue }
                candidates[parent.id] = parent
            }
        }
        for token in selfMessageIDSearchTokens {
            for child in fetchByHeaderToken(token, field: .inReplyTo, context: context) {
                guard child.id != message.id else { continue }
                candidates[child.id] = child
            }
            for child in fetchByHeaderToken(token, field: .referencesChain, context: context) {
                guard child.id != message.id else { continue }
                candidates[child.id] = child
            }
        }
        if candidates.isEmpty { return }

        // Run union-find over [message] + candidates. Only members of
        // the component that *contains the new message* are eligible
        // for thread assignment — unrelated header-token collisions
        // (rare but possible) stay in their own components.
        let inputs = [message] + Array(candidates.values)
        let componentByID = unionFindGroups(inputs, allowSubjectFallback: false)
        guard let myRoot = componentByID[message.id] else { return }

        var linkedMembers: [Message] = []
        for candidate in inputs {
            if componentByID[candidate.id] == myRoot {
                linkedMembers.append(candidate)
            }
        }

        // Collect the distinct pre-existing threads represented by
        // the linked members. Normally this is 0 or 1, but a new
        // message can *bridge* two previously-disjoint threads when
        // its headers reference members of both — that's the case
        // we have to actively merge, otherwise the two threads stay
        // permanently split. Pick the largest as the surviving
        // thread so we keep the bigger conversation's identity, then
        // re-point every member of the loser threads onto it.
        var existingThreads: [MessageThread] = []
        var seenThreadIDs = Set<UUID>()
        for member in linkedMembers {
            if let t = member.thread, seenThreadIDs.insert(t.id).inserted {
                existingThreads.append(t)
            }
        }
        existingThreads.sort { lhs, rhs in
            if lhs.messageCount != rhs.messageCount {
                return lhs.messageCount > rhs.messageCount
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let thread: MessageThread
        if let survivor = existingThreads.first {
            thread = survivor
            // Merge any losers into the survivor. SwiftData inverse
            // relationship semantics: reassigning `member.thread`
            // removes it from the loser's `messages` array and adds
            // it to the survivor's. Keep each emptied row as a tombstone:
            // another ModelContext may still be projecting its relationship,
            // and deleting the backing row would make that valid read trap.
            for loser in existingThreads.dropFirst() {
                let losersMembers = loser.messages
                for m in losersMembers {
                    m.thread = thread
                }
                refreshStats(for: loser)
            }
        } else {
            let subjectRoot = normalizedSubject(message.subject)
            let created = MessageThread(subjectRoot: subjectRoot)
            context.insert(created)
            thread = created
        }

        // Attach every linked member that doesn't already belong to
        // the surviving thread (covers both the new message itself
        // and any orphan candidates pulled in by the union-find
        // component).
        for member in linkedMembers where member.thread !== thread {
            member.thread = thread
        }

        applyReplyClearance(in: linkedMembers, context: context)
        refreshStats(for: thread)
    }

    // MARK: - Batch grouping (backfill path)

    /// Pure union-find over an arbitrary message set. Returns a
    /// `messageID → componentRootID` mapping. Single-message
    /// components are *omitted* from the returned dictionary so
    /// callers can treat absence-of-mapping as "orphan, no
    /// MessageThread row needed."
    public static func groupIntoThreads(_ messages: [Message]) -> [UUID: UUID] {
        guard messages.count > 1 else { return [:] }
        let componentByID = unionFindGroups(messages, allowSubjectFallback: true)

        var rootCounts: [UUID: Int] = [:]
        for root in componentByID.values {
            rootCounts[root, default: 0] += 1
        }

        var result: [UUID: UUID] = [:]
        for (id, root) in componentByID where rootCounts[root, default: 0] > 1 {
            result[id] = root
        }
        return result
    }

    /// Reconciliation over currently-unthreaded messages, invoked once at an
    /// ingestion milestone (local-seed completion, IMAP backfill completion).
    /// The first pass reruns header matching so repaired/delayed IMAP rows can
    /// attach to an existing `MessageThread`; the second groups the remaining
    /// rows via the normalized-subject + participant-overlap fallback for
    /// mangled envelope headers.
    ///
    /// Idempotent: only touches `thread == nil` rows, creates one thread per
    /// non-singleton component, and leaves genuine singletons unattached.
    /// Saves bounded progress and yields between orphan lookups so large
    /// historical imports do not monopolize their caller's actor. Cancellation
    /// preserves completed assignments; a later milestone resumes remaining rows.
    @discardableResult
    public static func reconcileOrphansBySubject(
        context: ModelContext,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> (threadsCreated: Int, messagesAttached: Int) {
        try Task.checkCancellation()
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.thread == nil }
        )
        let unthreaded = try context.fetch(descriptor)
        guard unthreaded.isEmpty == false else { return (0, 0) }

        let existingThreadIDs = Set(try context.fetch(FetchDescriptor<MessageThread>()).map(\.id))
        for (index, orphan) in unthreaded.enumerated() {
            // A mailbox mutation may remove or attach a row while this pass
            // yields. Never touch an invalidated model or overwrite new work.
            if orphan.modelContext != nil, !orphan.isDeleted, orphan.thread == nil {
                assignOnIngest(message: orphan, context: context)
            }
            if index.isMultiple(of: 8) || Task.isCancelled {
                try context.save()
            }
            try Task.checkCancellation()
            await Task.yield()
        }
        try context.save()
        try Task.checkCancellation()

        let retained = unthreaded.filter { $0.modelContext != nil && !$0.isDeleted }
        let headerAttachedMessages = retained.filter { $0.thread != nil }
        let headerThreadIDs = Set(headerAttachedMessages.compactMap { $0.thread?.id })
        let headerThreadsCreated = headerThreadIDs.subtracting(existingThreadIDs).count
        let remainingOrphans = retained.filter { $0.thread == nil }
        guard remainingOrphans.count > 1 else {
            return (headerThreadsCreated, headerAttachedMessages.count)
        }

        let componentByID = groupIntoThreads(remainingOrphans)
        if componentByID.isEmpty {
            return (headerThreadsCreated, headerAttachedMessages.count)
        }

        var membersByRoot: [UUID: [Message]] = [:]
        let messagesByID = Dictionary(uniqueKeysWithValues: remainingOrphans.map { ($0.id, $0) })
        for (id, root) in componentByID {
            guard let message = messagesByID[id] else { continue }
            membersByRoot[root, default: []].append(message)
        }

        var threadsCreated = 0
        var messagesAttached = 0
        for (_, originalMembers) in membersByRoot {
            let members = originalMembers.filter {
                $0.modelContext != nil && !$0.isDeleted && $0.thread == nil
            }
            guard members.count > 1 else { continue }

            // Thread subject root: normalized subject of the chronologically
            // earliest member (matches what a human calls the conversation).
            let earliest = members.min { lhs, rhs in
                let l = lhs.vectorTimeFilterDate ?? lhs.ingestedAt
                let r = rhs.vectorTimeFilterDate ?? rhs.ingestedAt
                return l < r
            }
            let subjectRoot = normalizedSubject(
                earliest?.subject ?? members.first?.subject ?? ""
            )

            let thread = MessageThread(subjectRoot: subjectRoot)
            context.insert(thread)
            for member in members {
                member.thread = thread
                messagesAttached += 1
            }
            applyReplyClearance(
                in: members,
                context: context,
                allowThreadFallback: true
            )
            refreshStats(for: thread)
            threadsCreated += 1
            try context.save()
            try Task.checkCancellation()
            await Task.yield()
        }
        return (
            headerThreadsCreated + threadsCreated,
            headerAttachedMessages.count + messagesAttached
        )
    }

    /// Recompute `messageCount`, `firstMessageAt`, `lastMessageAt`,
    /// `participantCount` for the given thread. Called both after
    /// `assignOnIngest` mutates membership and from the backfill
    /// applier after it attaches a batch of orphans.
    public static func refreshStats(for thread: MessageThread) {
        let members = thread.messages
        thread.messageCount = members.count

        var earliest: Date?
        var latest: Date?
        var participants = Set<String>()
        for m in members {
            if let d = m.vectorTimeFilterDate {
                if earliest == nil || d < earliest! { earliest = d }
                if latest == nil || d > latest! { latest = d }
            }
            let from = normalizedEmail(m.fromAddress)
            if !from.isEmpty { participants.insert(from) }
            for p in m.participants {
                if let email = p.participant?.emailAddress {
                    let n = normalizedEmail(email)
                    if !n.isEmpty { participants.insert(n) }
                }
            }
        }
        thread.firstMessageAt = earliest
        thread.lastMessageAt = latest
        thread.participantCount = participants.count
        if thread.subjectRoot.isEmpty {
            if let firstMember = members.first {
                thread.subjectRoot = normalizedSubject(firstMember.subject)
            }
        }
    }

    // MARK: - Internal: reply-state reconciliation

    /// A sent message that references an inbound Message-ID means the inbound
    /// action obligation has been answered. This also revokes Needs Reply or
    /// Needs Confirmation overrides that predate the sent reply and notifies
    /// cached attention surfaces. Subject-fallback reconciliation may use the
    /// persisted component only when the sent member has no direct header match.
    @discardableResult
    private static func applyReplyClearance(
        in messages: [Message],
        context: ModelContext,
        allowThreadFallback: Bool = false
    ) -> Set<UUID> {
        guard messages.count > 1 else { return [] }

        let inboundMessages = messages.filter { $0.isSentByUser == false }
        guard inboundMessages.isEmpty == false else { return [] }

        var inboundByMessageID: [String: [Message]] = [:]
        for message in inboundMessages {
            for token in messageIDTokens(from: message.messageIdHeader) {
                inboundByMessageID[token, default: []].append(message)
            }
        }
        if !allowThreadFallback, inboundByMessageID.isEmpty {
            return []
        }

        let sentMessages = messages
            .filter { message in
                message.isSentByUser && !isOhiaComposerMailboxDraft(message)
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.vectorTimeFilterDate ?? lhs.ingestedAt
                let rhsDate = rhs.vectorTimeFilterDate ?? rhs.ingestedAt
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard sentMessages.isEmpty == false else { return [] }

        var replyActionsByMessageID: [UUID: [ProjectLensAction]] = [:]
        let actions = (try? context.fetch(FetchDescriptor<ProjectLensAction>())) ?? []
        for action in actions where action.isActive && action.targetKind == .message {
            guard let messageID = action.messageId else { continue }
            switch action.actionValue {
            case .replyNeededByUser, .confirmationNeededByUser:
                replyActionsByMessageID[messageID, default: []].append(action)
            default:
                break
            }
        }

        var changedMessageIDs = Set<UUID>()
        for sent in sentMessages {
            let sentDate = sent.vectorTimeFilterDate ?? sent.ingestedAt
            var matchedInboundByID: [UUID: Message] = [:]
            for referencedToken in referencedMessageIDTokens(for: sent) {
                for inbound in inboundByMessageID[referencedToken] ?? [] {
                    matchedInboundByID[inbound.id] = inbound
                }
            }
            if matchedInboundByID.isEmpty, allowThreadFallback {
                for inbound in inboundMessages {
                    matchedInboundByID[inbound.id] = inbound
                }
            }

            for inbound in matchedInboundByID.values {
                let inboundDate = inbound.vectorTimeFilterDate ?? inbound.ingestedAt
                guard sentDate > inboundDate else { continue }
                let previousRepliedAt = inbound.repliedAt
                var didChange = false
                if previousRepliedAt.map({ sentDate < $0 }) ?? true {
                    inbound.repliedAt = sentDate
                    didChange = true
                }
                if inbound.requiresReply {
                    inbound.requiresReply = false
                    didChange = true
                }
                for action in replyActionsByMessageID[inbound.id] ?? []
                where action.isActive && action.appliedAt <= sentDate {
                    action.revoke(at: sentDate)
                    didChange = true
                }
                if didChange {
                    changedMessageIDs.insert(inbound.id)
                }
            }
        }
        if changedMessageIDs.isEmpty == false {
            NotificationCenter.default.post(
                name: .ohiaMessageAttentionChanged,
                object: nil,
                userInfo: [
                    MessageAttentionNotificationUserInfoKey.messageIDs: changedMessageIDs
                        .map(\.uuidString)
                        .sorted()
                ]
            )
        }
        return changedMessageIDs
    }

    /// Composer's provider-synced mailbox drafts are authored by the user but
    /// have not crossed the SMTP acceptance boundary. If one is observed by a
    /// corpus ingestion path, its stable draft Message-ID must not satisfy a
    /// thread's replied state.
    private static func isOhiaComposerMailboxDraft(_ message: Message) -> Bool {
        isOhiaComposerMailboxDraftMessageID(message.messageIdHeader)
    }

    // MARK: - Internal: union-find core

    /// Union-find used by both entry points. With
    /// `allowSubjectFallback == false` only the header graph is
    /// walked; with `true` we also union messages whose normalized
    /// subject matches and whose participant sets overlap.
    static func unionFindGroups(
        _ messages: [Message],
        allowSubjectFallback: Bool
    ) -> [UUID: UUID] {
        guard !messages.isEmpty else { return [:] }

        var byMessageIDHeader: [String: [UUID]] = [:]
        var byReferenced: [String: [UUID]] = [:]
        for message in messages {
            for token in messageIDTokens(from: message.messageIdHeader) {
                byMessageIDHeader[token, default: []].append(message.id)
            }
            for token in referencedMessageIDTokens(for: message) {
                byReferenced[token, default: []].append(message.id)
            }
        }

        var parent: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: messages.map { ($0.id, $0.id) }
        )

        func find(_ id: UUID) -> UUID {
            var current = id
            while parent[current]! != current { current = parent[current]! }
            let root = current
            var node = id
            while parent[node]! != root {
                let next = parent[node]!
                parent[node] = root
                node = next
            }
            return root
        }

        func union(_ lhs: UUID, _ rhs: UUID) {
            let rootL = find(lhs)
            let rootR = find(rhs)
            guard rootL != rootR else { return }
            if rootL.uuidString < rootR.uuidString {
                parent[rootR] = rootL
            } else {
                parent[rootL] = rootR
            }
        }

        for message in messages {
            for token in messageIDTokens(from: message.messageIdHeader) {
                for childId in byReferenced[token] ?? [] {
                    union(message.id, childId)
                }
            }
            for token in referencedMessageIDTokens(for: message) {
                for parentId in byMessageIDHeader[token] ?? [] {
                    union(message.id, parentId)
                }
                for siblingId in byReferenced[token] ?? [] {
                    union(message.id, siblingId)
                }
            }
        }

        if allowSubjectFallback {
            var subjectBuckets: [String: [Message]] = [:]
            for message in messages {
                let normalized = normalizedSubject(message.subject)
                guard !normalized.isEmpty, normalized.count >= 3 else { continue }
                subjectBuckets[normalized, default: []].append(message)
            }
            for (_, bucket) in subjectBuckets where bucket.count > 1 {
                for i in 0..<bucket.count {
                    let center = bucket[i]
                    let centerParticipants = participantEmails(
                        for: center,
                        excluding: center.account?.emailAddress
                    )
                    for j in (i + 1)..<bucket.count {
                        let candidate = bucket[j]
                        if hasParticipantOverlap(
                            candidate,
                            centerParticipants: centerParticipants,
                            center: center
                        ) {
                            union(center.id, candidate.id)
                        }
                    }
                }
            }
        }

        var componentByID: [UUID: UUID] = [:]
        for message in messages {
            componentByID[message.id] = find(message.id)
        }
        return componentByID
    }

    // MARK: - Internal: predicate-driven candidate fetch

    private enum HeaderField {
        case messageIDHeader
        case inReplyTo
        case referencesChain
    }

    private static func fetchByHeaderToken(
        _ token: String,
        field: HeaderField,
        context: ModelContext
    ) -> [Message] {
        guard let normalizedToken = normalizeMessageIDHeader(token) else { return [] }
        // SwiftData's `#Predicate` macro doesn't accept dynamic
        // KeyPaths, so we branch on the field at compile time.
        //
        // Substring containment trade-off: real RFC-5322 Message-IDs are 30–80
        // char random local-parts + domain, so the chance of one being a
        // literal substring of another is vanishingly small in real mail. The
        // in-memory normalized-token filter below rejects accidental predicate
        // overmatches.
        let bracketed = "<\(token)>"
        let normalizedBracketed = "<\(normalizedToken)>"
        let descriptor: FetchDescriptor<Message>
        switch field {
        case .messageIDHeader:
            descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { m in
                    m.messageIdHeader != nil
                        && (m.messageIdHeader!.contains(token)
                            || m.messageIdHeader!.contains(bracketed)
                            || m.messageIdHeader!.contains(normalizedToken)
                            || m.messageIdHeader!.contains(normalizedBracketed))
                }
            )
        case .inReplyTo:
            descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { m in
                    m.inReplyTo != nil
                        && (m.inReplyTo!.contains(token)
                            || m.inReplyTo!.contains(bracketed)
                            || m.inReplyTo!.contains(normalizedToken)
                            || m.inReplyTo!.contains(normalizedBracketed))
                }
            )
        case .referencesChain:
            descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { m in
                    m.referencesChain != nil
                        && (m.referencesChain!.contains(token)
                            || m.referencesChain!.contains(bracketed)
                            || m.referencesChain!.contains(normalizedToken)
                            || m.referencesChain!.contains(normalizedBracketed))
                }
            )
        }
        let matches = ((try? context.fetch(descriptor)) ?? [])
            .filter { headerField(field, of: $0).map { messageIDTokens(from: $0).contains(normalizedToken) } ?? false }
        if matches.isEmpty == false { return matches }

        let fallbackDescriptor: FetchDescriptor<Message>
        switch field {
        case .messageIDHeader:
            fallbackDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.messageIdHeader != nil }
            )
        case .inReplyTo:
            fallbackDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.inReplyTo != nil }
            )
        case .referencesChain:
            fallbackDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.referencesChain != nil }
            )
        }
        return ((try? context.fetch(fallbackDescriptor)) ?? [])
            .filter { headerField(field, of: $0).map { messageIDTokens(from: $0).contains(normalizedToken) } ?? false }
    }

    private static func headerField(_ field: HeaderField, of message: Message) -> String? {
        switch field {
        case .messageIDHeader:
            return message.messageIdHeader
        case .inReplyTo:
            return message.inReplyTo
        case .referencesChain:
            return message.referencesChain
        }
    }

    // MARK: - Internal: header / subject / participant normalization

    static func messageIDTokens(from value: String?) -> Set<String> {
        normalizedMessageIDTokens(value)
    }

    static func referencedMessageIDTokens(for message: Message) -> Set<String> {
        messageIDTokens(from: message.inReplyTo)
            .union(messageIDTokens(from: message.referencesChain))
    }

    static func messageIDSearchTokens(from value: String?) -> Set<String> {
        guard let value else { return [] }
        let tokens = value
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .flatMap { raw -> [String] in
                let stripped = String(raw).trimmingCharacters(
                    in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>,"))
                )
                guard stripped.isEmpty == false else { return [] }
                if let normalized = normalizeMessageIDHeader(stripped), normalized != stripped {
                    return [stripped, normalized]
                }
                return [stripped]
            }
        return Set(tokens)
    }

    static func referencedMessageIDSearchTokens(for message: Message) -> Set<String> {
        messageIDSearchTokens(from: message.inReplyTo)
            .union(messageIDSearchTokens(from: message.referencesChain))
    }

    public static func normalizedSubject(_ subject: String) -> String {
        var value = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["re:", "fwd:", "fw:"] where value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
            }
        }
        return value
    }

    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func participantEmails(
        for message: Message,
        excluding excludedEmail: String?
    ) -> Set<String> {
        let excluded = normalizedEmail(excludedEmail ?? "")
        var emails = Set<String>()
        let from = normalizedEmail(message.fromAddress)
        if !from.isEmpty { emails.insert(from) }
        for participant in message.participants {
            guard let email = participant.participant?.emailAddress else { continue }
            let normalized = normalizedEmail(email)
            if !normalized.isEmpty { emails.insert(normalized) }
        }
        if !excluded.isEmpty { emails.remove(excluded) }
        return emails
    }

    static func hasParticipantOverlap(
        _ candidate: Message,
        centerParticipants: Set<String>,
        center: Message
    ) -> Bool {
        let candidateParticipants = participantEmails(
            for: candidate,
            excluding: center.account?.emailAddress
        )
        if !centerParticipants.isEmpty, !candidateParticipants.isEmpty {
            return !centerParticipants.isDisjoint(with: candidateParticipants)
        }
        let centerSender = normalizedEmail(center.fromAddress)
        let candidateSender = normalizedEmail(candidate.fromAddress)
        return !centerSender.isEmpty && centerSender == candidateSender
    }
}
