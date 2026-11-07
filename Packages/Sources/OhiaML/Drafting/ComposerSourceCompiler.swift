import Foundation
import SwiftData
import OhiaCore

/// Compiles the automatic evidence set for a reply before clarifying
/// questions are generated: earlier messages in the thread, the user's most
/// recent replies, related cross-thread messages, dimension-matched memory
/// notes, extracted attachment content, dates, calendar availability, and URLs.
///
/// Deliberately embedding-runtime-free — it runs inside the generative
/// worker's `.generateDraft` intake, where the BGE model is never loaded.
/// Everything here comes from SwiftData fetches, canonical body/attachment
/// text files, and optional already-persisted semantic-neighborhood evidence.
/// Live semantic retrieval still happens separately through the generation
/// context pack; these sources are the deterministic floor the question model
/// can answer from.
@MainActor
public enum ComposerSourceCompiler {

    public struct Limits: Sendable {
        public var memoryNotes = 5
        public var attachments = 3
        public var relatedMessages = 8
        public var websites = 3
        public var calendarEvents = 12
        public var calendarLookaheadDays = 14
        public var calendarFallbackLookaheadDays = 7
        /// An outer relevance/cost ceiling on how far back a Messages
        /// transcript reaches — not a prompt-size control. `ComposerContextPacker`
        /// is the actual size arbiter (see `ComposerContextPacker.pack`); these
        /// two exist only because pulling in someone's entire multi-year chat
        /// history regardless of budget is never useful and would slow the
        /// chat.db query for no benefit. Matches `SourceMessagesPickerSheet`'s
        /// own Stepper ceiling, so the automatic and manual paths agree on
        /// what "as much history as anyone would reasonably want" means.
        public var messages = 200
        public var messagesMaxAgeDays = 365
        /// Bounds an *intermediate* computation only — how much of an
        /// attachment's text feeds into a related-message candidate's preview
        /// before scoring/ranking (see `relatedSnippet`). Not used to cap any
        /// source's final snippet; `ComposerContextPacker` owns that sizing
        /// for every automatic source, using the model's real token budget.
        public var snippetCharacters = 700
        /// Bounds only the legacy recent-message fallback used for non-tag
        /// bridges. Canonical-tag members are fetched directly by indexed tag
        /// ID across the account and are not gated by this recency window.
        public var relatedScanLimit = 600
        /// Bounds relationship hydration for an exceptionally broad canonical
        /// tag by membership quality, never by message date. The next stage
        /// applies issue/role ranking before any body files are read.
        public var canonicalMembershipScanLimit = 2_000
        /// Maximum canonical candidates whose full bodies can enter the
        /// expensive relevance pass. The shortlist is built from tag
        /// specificity, role agreement, and subject/summary issue overlap.
        public var canonicalEvaluationLimit = 400
        public var relatedMinimumScore = 2.6
        public init() {}
        public static let `default` = Limits()
    }

    /// Returns automatic sources for the message, newest-relevant first
    /// within each kind. Never throws — a missing body file or thread just
    /// yields fewer sources.
    public static func compile(
        for message: Message,
        context: ModelContext,
        limits: Limits = .default,
        now: Date = Date(),
        calendarAvailabilityProvider: ComposerCalendarAvailabilityProvider? = nil,
        calendarAvailabilityEnabled: Bool = ComposerSourceProviderPreference.isEnabled(.calendar),
        relatedAffinityProvider: (any ComposerRelatedAffinityProviding)? = nil,
        embedder: (any EmbeddingProvider)? = nil
    ) -> [ComposerSource] {
        var sources: [ComposerSource] = []
        if let threadState = threadStateSource(for: message) {
            sources.append(threadState)
        }
        sources.append(contentsOf: threadSources(for: message))
        sources.append(contentsOf: relatedMessageSources(
            for: message,
            context: context,
            excluding: Set(sources.compactMap(\.messageID)),
            limits: limits,
            relatedAffinityProvider: relatedAffinityProvider
        ))
        sources.append(contentsOf: memorySources(for: message, context: context, limits: limits, embedder: embedder))
        sources.append(contentsOf: attachmentSources(for: message, limits: limits))
        sources.append(contentsOf: calendarSources(
            for: message,
            limits: limits,
            now: now,
            availabilityProvider: calendarAvailabilityProvider,
            availabilityEnabled: calendarAvailabilityEnabled
        ))
        sources.append(contentsOf: websiteSources(
            for: message,
            contextSources: sources,
            context: context,
            limits: limits
        ))
        return sources
    }

    static func compileMinimal(for message: Message) -> [ComposerSource] {
        var sources: [ComposerSource] = []
        let anchorTerms = minimalPassageAnchorTerms(for: message)
        if let state = threadStateSource(
            for: message,
            anchorTerms: anchorTerms
        ) {
            sources.append(state)
        }
        // The replied-to message is the author's latest word whenever it is
        // theirs; when it is missing from the store, its quoted copy stands in.
        if let recovered = recoveredParentSource(for: message, anchorTerms: anchorTerms),
           recovered.source.authoredByUser == true {
            sources.append(recovered.source)
            return Array(sources.prefix(2))
        }
        let own = ownIdentity(for: message)
        let targetDate = sourceDate(for: message)
        let newestUserMessage = threadSiblings(for: message)
            .filter {
                own.wrote($0) && sourceDate(for: $0) < targetDate
            }
            .sorted {
                let leftDate = sourceDate(for: $0)
                let rightDate = sourceDate(for: $1)
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
        if let newestUserMessage,
           let source = threadSource(for: newestUserMessage, anchorTerms: anchorTerms, own: own) {
            sources.append(source)
        }
        return Array(sources.prefix(2))
    }

    /// The thread as it stands for `message`: every stored member plus the
    /// Message-ID of a missing parent whose quoted copy the thread sources
    /// carry. Recorded with the compiled sources so a later arrival of an
    /// earlier email can be detected.
    public static func threadCoverage(for message: Message) -> ComposerThreadCoverage {
        var messageIDs = Set((message.thread?.messages ?? []).map(\.id))
        messageIDs.insert(message.id)
        var quoted = Set<String>()
        if let headers = missingParentHeaders(for: message),
           recoveredParent(for: message) != nil {
            quoted.formUnion(headers)
        }
        return ComposerThreadCoverage(messageIDs: messageIDs, quotedMessageIDHeaders: quoted)
    }

    /// Thread sources for specific earlier members, built exactly as the full
    /// compile builds them. Used to extend an author-edited draft with emails
    /// that reached the thread after its sources were compiled.
    public static func threadSources(
        for message: Message,
        members: [Message]
    ) -> [ComposerSource] {
        let anchorTerms = passageAnchorTerms(for: message)
        let own = ownIdentity(for: message)
        return members.compactMap { threadSource(for: $0, anchorTerms: anchorTerms, own: own) }
    }

    /// Merges a fresh automatic compilation into an existing persisted list,
    /// preserving every user-added source and the user's ordering of them.
    public static func mergingAutomaticSources(
        into existing: [ComposerSource],
        for message: Message,
        context: ModelContext,
        limits: Limits = .default,
        now: Date = Date(),
        calendarAvailabilityProvider: ComposerCalendarAvailabilityProvider? = nil,
        calendarAvailabilityEnabled: Bool = ComposerSourceProviderPreference.isEnabled(.calendar),
        relatedAffinityProvider: (any ComposerRelatedAffinityProviding)? = nil,
        embedder: (any EmbeddingProvider)? = nil
    ) -> [ComposerSource] {
        let userAdded = existing.filter(\.isUserAdded)
        return compile(
            for: message,
            context: context,
            limits: limits,
            now: now,
            calendarAvailabilityProvider: calendarAvailabilityProvider,
            calendarAvailabilityEnabled: calendarAvailabilityEnabled,
            relatedAffinityProvider: relatedAffinityProvider,
            embedder: embedder
        ) + userAdded
    }

    // MARK: - Thread history

    private static func threadSources(for message: Message) -> [ComposerSource] {
        let anchorTerms = passageAnchorTerms(for: message)
        let priorMessages = threadSiblings(for: message)
            .sorted {
                let leftDate = sourceDate(for: $0)
                let rightDate = sourceDate(for: $1)
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        let own = ownIdentity(for: message)
        var sources = priorMessages.compactMap {
            threadSource(for: $0, anchorTerms: anchorTerms, own: own)
        }
        if let recovered = recoveredParentSource(for: message, anchorTerms: anchorTerms) {
            // Newest first: the parent precedes the reply but follows every
            // stored ancestor older than it.
            let anchorDate = recovered.date ?? sourceDate(for: message)
            let insertion = sources.firstIndex { source in
                guard let id = source.messageID,
                      let sibling = priorMessages.first(where: { $0.id == id }) else {
                    return false
                }
                return sourceDate(for: sibling) <= anchorDate
            } ?? sources.endIndex
            sources.insert(recovered.source, at: insertion)
        }
        return sources
    }

    /// The normalized In-Reply-To Message-IDs when no stored thread member
    /// carries any of them — the replied-to message has not reached the store.
    private static func missingParentHeaders(for message: Message) -> Set<String>? {
        let parents = Set(ComposerThreadCoverage.messageIDTokens(message.inReplyTo))
        guard !parents.isEmpty else { return nil }
        let stored = Set(threadSiblings(for: message).flatMap {
            ComposerThreadCoverage.messageIDTokens($0.messageIdHeader)
        })
        return parents.isDisjoint(with: stored) ? parents : nil
    }

    private static func recoveredParent(for message: Message) -> QuotedParentText.Recovered? {
        guard missingParentHeaders(for: message) != nil,
              let path = message.bodyTextPath,
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return QuotedParentText.recover(from: raw)
    }

    /// A thread source for a missing replied-to message, recovered from the
    /// incoming email's quoted history. Authorship is resolved against every
    /// address the author sends from so their last word is attributed to
    /// them, never to the correspondent who quoted it. The quoted date is
    /// read in this machine's time zone; it is clamped to the reply's date,
    /// which the parent cannot follow.
    private static func recoveredParentSource(
        for message: Message,
        anchorTerms: [String]
    ) -> (source: ComposerSource, date: Date?)? {
        guard let recovered = recoveredParent(for: message) else { return nil }
        let snippet = passageSelector.select(from: recovered.text, anchorTerms: anchorTerms)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { return nil }

        let authoredByUser = ownIdentity(for: message).wrote(recovered)
        let date = recovered.date.map { min($0, sourceDate(for: message)) }
        let author: String
        if authoredByUser {
            author = "you"
        } else if let address = recovered.authorAddress,
                  let known = ([message] + threadSiblings(for: message)).first(where: {
                      $0.fromAddress.lowercased() == address
                  }) {
            author = known.fromName ?? known.fromAddress
        } else {
            author = recovered.authorName ?? recovered.authorAddress ?? "an earlier message"
        }
        var label = author == "an earlier message" ? author : "\(author) wrote"
        if let date {
            label += " · \(sourceDateFormatter.string(from: date))"
        }
        label += " · quoted in \(message.fromName ?? message.fromAddress)'s email"
        return (
            ComposerSource(
                kind: .thread,
                label: label,
                snippet: snippet,
                authoredByUser: authoredByUser,
                // The replied-to message immediately precedes the reply, so it
                // orders as the reply's own time: a quoted date is read in this
                // machine's time zone and could otherwise sort it behind a
                // stored message it actually follows.
                authoredAt: sourceDate(for: message)
            ),
            date
        )
    }

    /// The author's own addresses and names: every account and identity
    /// (the replying account can be unset, and the author may write from
    /// another account) plus the senders of the thread's user-sent messages,
    /// which covers send-as aliases that are not configured identities.
    struct OwnIdentity {
        let addresses: Set<String>
        let names: Set<String>

        /// A stored message is the author's when ingestion marked it sent,
        /// or when it came from one of the author's addresses through
        /// another account (a reply sent from a second account arrives in
        /// this one as received mail).
        func wrote(_ message: Message) -> Bool {
            message.isSentByUser || addresses.contains(Self.normalized(message.fromAddress))
        }

        func wrote(_ recovered: QuotedParentText.Recovered) -> Bool {
            if let address = recovered.authorAddress {
                return addresses.contains(address)
            }
            guard let name = recovered.authorName.map(Self.normalized), !name.isEmpty else {
                return false
            }
            return names.contains(name)
        }

        static func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    static func ownIdentity(for message: Message) -> OwnIdentity {
        let accounts = (try? message.modelContext?.fetch(FetchDescriptor<Account>())) ?? []
        let ownSent = ([message] + threadSiblings(for: message)).filter(\.isSentByUser)
        func normalized(_ values: [String]) -> Set<String> {
            Set(values.map(OwnIdentity.normalized).filter { !$0.isEmpty })
        }
        return OwnIdentity(
            addresses: normalized(
                accounts.flatMap { [$0.emailAddress] + $0.identities.map(\.address) }
                    + ownSent.map(\.fromAddress)
            ),
            names: normalized(
                accounts.flatMap { [$0.displayName] + $0.identities.compactMap(\.displayName) }
                    + ownSent.compactMap(\.fromName)
            )
        )
    }

    private static func threadSource(
        for message: Message,
        anchorTerms: [String],
        own: OwnIdentity
    ) -> ComposerSource? {
        guard let snippet = selectedBodySnippet(
            of: message,
            anchorTerms: anchorTerms
        ) else {
            return nil
        }
        // "wrote" attribution on both directions: the digest resolves each
        // snippet's "I"/"you" from these labels, so an inbound sibling must
        // state its author, not just carry a bare name.
        let authoredByUser = own.wrote(message)
        let direction = authoredByUser
            ? "you wrote"
            : "\(message.fromName ?? message.fromAddress) wrote"
        return ComposerSource(
            kind: .thread,
            label: "\(direction) · \(dateLabel(for: message))",
            snippet: snippet,
            messageID: message.id,
            authoredByUser: authoredByUser,
            authoredAt: sourceDate(for: message)
        )
    }

    private static func threadStateSource(for message: Message) -> ComposerSource? {
        threadStateSource(
            for: message,
            anchorTerms: passageAnchorTerms(for: message)
        )
    }

    private static func threadStateSource(
        for message: Message,
        anchorTerms: [String]
    ) -> ComposerSource? {
        let siblings = threadSiblings(for: message)
            .sorted {
                let leftDate = sourceDate(for: $0)
                let rightDate = sourceDate(for: $1)
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        guard siblings.isEmpty == false else { return nil }

        var lines: [String] = []
        var seen = Set<String>()
        for sibling in siblings {
            guard let json = sibling.analysis?.discourseMemoryJSON,
                  let memory = try? DiscourseMemory.decode(json) else {
                continue
            }
            let author = sibling.isSentByUser
                ? "you"
                : (sibling.fromName ?? sibling.fromAddress)
            let attribution = "\(dateLabel(for: sibling)) · \(author)"

            func append(_ label: String, _ rawText: String) {
                let text = compactLine(rawText)
                guard text.isEmpty == false else { return }
                let key = "\(label.lowercased())\u{1f}\(text.lowercased())"
                guard seen.insert(key).inserted else { return }
                lines.append("\(attribution) — \(label): \(text)")
            }

            for candidate in memory.decisionCandidates
            where candidate.support.qualifiesAsCandidate {
                append("Decision", candidate.text)
            }
            for signal in memory.contradictionSignals
            where signal.support.qualifiesAsCandidate {
                append("Contradiction", signal.conflictingClaim)
            }
            for signal in memory.supersessionSignals
            where signal.support.qualifiesAsCandidate {
                append("Supersession", signal.newerStatement)
            }
            for uncertainty in memory.uncertainties
            where isComposerThreadStateUncertainty(uncertainty) {
                let question = compactLine(uncertainty.question)
                let candidate = compactLine(uncertainty.candidate)
                let text = candidate.isEmpty ? question : "\(question) — \(candidate)"
                append("Uncertainty", text)
            }
        }
        guard lines.isEmpty == false else { return nil }

        let packed = passageSelector.select(
            from: lines.joined(separator: "\n"),
            anchorTerms: anchorTerms,
            preservingBoundaryChunks: true
        )
        guard packed.isEmpty == false else { return nil }
        return ComposerSource(
            kind: .threadState,
            label: "Thread history",
            snippet: "Historical observations, oldest first. Later authored replies may resolve these questions; these are not verified open issues.\n" + packed,
            messageID: message.id
        )
    }

    /// Discourse extraction records its own durability-review bookkeeping as
    /// uncertainties. Those lines explain whether a summary should become
    /// long-term memory; they are not unresolved facts in the conversation
    /// and must not be promoted as the thread's current state.
    private static func isComposerThreadStateUncertainty(
        _ uncertainty: Uncertainty
    ) -> Bool {
        let question = compactLine(uncertainty.question).lowercased()
        let candidate = compactLine(uncertainty.candidate).lowercased()
        let durabilityMetadata = question.hasPrefix("does this summary contain a durable claim")
            || question.hasPrefix("should this summary become durable memory")
            || candidate.hasPrefix("excluded from durable memory")
        return !durabilityMetadata
    }

    private static func threadSiblings(for message: Message) -> [Message] {
        message.thread?.messages.filter { $0.id != message.id } ?? []
    }

    private static func contextualThreadMessages(for message: Message) -> [Message] {
        [message] + threadSiblings(for: message).filter { $0.isAutomatedOrBulk != true }
    }

    private static func passageAnchorTerms(for message: Message) -> [String] {
        contextualThreadMessages(for: message)
            .reduce(into: Set<String>()) { terms, threadMessage in
                terms.formUnion(ComposerSourceRelevance.relevanceTerms(for: threadMessage))
            }
            .sorted()
    }

    private static func minimalPassageAnchorTerms(for message: Message) -> [String] {
        var textParts = [message.subject]
        if let cleanedBody = ComposerSourceRelevance.cleanedBodyText(for: message) {
            textParts.append(cleanedBody)
        }
        return ComposerSourceRelevance.tokens(
            textParts.joined(separator: "\n"),
            maxTokens: 200
        )
        .sorted()
    }

    private static func isAddressed(_ sent: Message, to correspondent: String) -> Bool {
        sent.participants.contains { link in
            guard link.role == .to || link.role == .cc else { return false }
            return link.participant?.emailAddress.lowercased() == correspondent
        }
    }

    // MARK: - Related cross-thread messages

    private struct RelatedCandidate {
        let message: Message
        let score: Double
        let snippet: String
    }

    private struct SemanticIntentCandidateSeed {
        let message: Message
        let tagMatchScore: Double
        let membershipWeight: Double
        let hasHardQualifier: Bool
        let shortlistScore: Double
    }

    private struct CanonicalTagAnchor {
        let tagID: UUID
        let weight: Double
        let roles: Set<SemanticTagRole>
    }

    private struct RelatedCanonicalTagAnchor {
        let tagID: UUID
        let affinity: Double
        let roles: Set<SemanticTagRole>
    }

    struct CanonicalTagCandidateEvidence {
        var exactAffinity = 0.0
        var relatedAffinity = 0.0
        var matchingRoleCount = 0
        var matchingRoles = Set<SemanticTagRole>()
        var accountMembershipCount = 0
        var hasHardQualifier = false

        var hasExactMatch: Bool { exactAffinity > 0 }

        func exactMatchQualifies(
            topicalOverlap: Int,
            sharedIdentifiers: Int
        ) -> Bool {
            guard hasExactMatch else { return false }
            return hasHardQualifier
                || accountMembershipCount <= 8
                || matchingRoleCount > 0
                || sharedIdentifiers > 0
                || topicalOverlap >= 2
        }

        func relatedMatchQualifies(
            topicalOverlap: Int,
            sharedIdentifiers: Int,
            hasStrongStoredAffinity: Bool
        ) -> Bool {
            guard relatedAffinity > 0 else { return false }
            return sharedIdentifiers > 0
                || topicalOverlap >= 2
                || (topicalOverlap == 1
                    && (matchingRoleCount > 0 || hasStrongStoredAffinity))
        }
    }

    private struct RelatedCandidateCorpus {
        let messages: [Message]
        let canonicalEvidenceByMessageID: [UUID: CanonicalTagCandidateEvidence]
    }

    private static func relatedMessageSources(
        for message: Message,
        context: ModelContext,
        excluding existingMessageIDs: Set<UUID>,
        limits: Limits,
        relatedAffinityProvider: (any ComposerRelatedAffinityProviding)?
    ) -> [ComposerSource] {
        guard limits.relatedMessages > 0 else { return [] }
        let corpus = relatedCandidateCorpus(for: message, context: context, limits: limits)
        let candidates = corpus.messages
        guard candidates.isEmpty == false else { return [] }
        let storedAffinities = relatedAffinityProvider?.affinities(
            anchorMessageID: message.id,
            candidateMessageIDs: Set(candidates.map(\.id)),
            limit: limits.relatedScanLimit
        ) ?? [:]

        let currentThreadIDs = Set((message.thread?.messages ?? []).map(\.id))
        var excluded = existingMessageIDs
        excluded.insert(message.id)
        let eligibleCandidates = candidates.filter { candidate in
            !excluded.contains(candidate.id) && !currentThreadIDs.contains(candidate.id)
        }
        let relevanceScores = crossThreadRelevanceScores(
            for: message,
            candidates: eligibleCandidates,
            context: context,
            storedAffinities: storedAffinities,
            canonicalEvidenceByMessageID: corpus.canonicalEvidenceByMessageID,
            minimumScore: limits.relatedMinimumScore
        )
        let anchorTerms = passageAnchorTerms(for: message)

        let qualified = eligibleCandidates.compactMap { candidate -> RelatedCandidate? in
            guard let score = relevanceScores[candidate.id] else { return nil }
            let candidateText = ComposerSourceRelevance.messageText(
                for: candidate,
                bodyLimit: 3_200,
                attachmentLimit: 1_500
            )
            guard let snippet = relatedSnippet(
                of: candidate,
                fallbackText: candidateText,
                attachmentLimit: limits.snippetCharacters,
                anchorTerms: anchorTerms
            ) else {
                return nil
            }
            return RelatedCandidate(message: candidate, score: score, snippet: snippet)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.message.receivedAt ?? $0.message.sentAt ?? $0.message.ingestedAt)
                > ($1.message.receivedAt ?? $1.message.sentAt ?? $1.message.ingestedAt)
        }
        return bundledRelatedSources(
            for: message,
            candidates: qualified,
            limit: limits.relatedMessages,
            attachmentLimit: limits.snippetCharacters,
            anchorTerms: anchorTerms
        )
    }

    /// Converts qualified historical messages into inspectable conversation
    /// packets. Once any message in a historical thread passes the hard
    /// relevance gate, the packet includes the authored messages on both
    /// sides of that conversation. The context packer remains the final size
    /// boundary and may passage-select the packet to fit the model budget.
    static func bundledRelatedSources(
        for message: Message,
        messages: [Message],
        relevanceScores: [UUID: Double],
        fallbackSnippets: [UUID: String] = [:],
        limit: Int = Limits.default.relatedMessages
    ) -> [ComposerSource] {
        let anchorTerms = passageAnchorTerms(for: message)
        let candidates = messages.compactMap { candidate -> RelatedCandidate? in
            guard let score = relevanceScores[candidate.id] else { return nil }
            let candidateText = fallbackSnippets[candidate.id] ?? ComposerSourceRelevance.messageText(
                for: candidate,
                bodyLimit: 3_200,
                attachmentLimit: 1_500
            )
            guard let snippet = relatedSnippet(
                of: candidate,
                fallbackText: candidateText,
                attachmentLimit: Limits.default.snippetCharacters,
                anchorTerms: anchorTerms
            ) else {
                return nil
            }
            return RelatedCandidate(message: candidate, score: score, snippet: snippet)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return sourceDate(for: $0.message) > sourceDate(for: $1.message)
        }
        return bundledRelatedSources(
            for: message,
            candidates: candidates,
            limit: limit,
            attachmentLimit: Limits.default.snippetCharacters,
            anchorTerms: anchorTerms
        )
    }

    private static func bundledRelatedSources(
        for message: Message,
        candidates: [RelatedCandidate],
        limit: Int,
        attachmentLimit: Int,
        anchorTerms: [String]
    ) -> [ComposerSource] {
        guard limit > 0 else { return [] }
        var grouped: [UUID: [RelatedCandidate]] = [:]
        for candidate in candidates {
            let key = candidate.message.thread?.id ?? candidate.message.id
            grouped[key, default: []].append(candidate)
        }

        let rankedGroups = grouped.values.sorted { left, right in
            let leftScore = left.map(\.score).max() ?? 0
            let rightScore = right.map(\.score).max() ?? 0
            if leftScore != rightScore { return leftScore > rightScore }
            let leftDate = left.map { sourceDate(for: $0.message) }.max() ?? .distantPast
            let rightDate = right.map { sourceDate(for: $0.message) }.max() ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            let leftID = left.map(\.message.id.uuidString).min() ?? ""
            let rightID = right.map(\.message.id.uuidString).min() ?? ""
            return leftID < rightID
        }

        return rankedGroups.prefix(limit).compactMap { group in
            guard let representative = group.sorted(by: {
                if $0.score != $1.score { return $0.score > $1.score }
                return sourceDate(for: $0.message) > sourceDate(for: $1.message)
            }).first else {
                return nil
            }

            let conversationMessages: [Message]
            if let thread = representative.message.thread {
                conversationMessages = thread.messages.filter {
                    $0.id != message.id && $0.isAutomatedOrBulk != true
                }
            } else {
                conversationMessages = group.map(\.message)
            }
            var seen = Set<UUID>()
            let orderedMessages = conversationMessages
                .filter { seen.insert($0.id).inserted }
                .sorted {
                    let leftDate = sourceDate(for: $0)
                    let rightDate = sourceDate(for: $1)
                    if leftDate != rightDate { return leftDate < rightDate }
                    return $0.id.uuidString < $1.id.uuidString
                }

            let blocks = orderedMessages.compactMap { historical -> String? in
                let fallback = ComposerSourceRelevance.messageText(
                    for: historical,
                    bodyLimit: 3_200,
                    attachmentLimit: 1_500
                )
                guard let snippet = relatedSnippet(
                    of: historical,
                    fallbackText: fallback,
                    attachmentLimit: attachmentLimit,
                    anchorTerms: anchorTerms
                ) else {
                    return nil
                }
                let author = historical.isSentByUser
                    ? "you wrote"
                    : "\(historical.fromName ?? historical.fromAddress) wrote"
                return "\(author) · \(dateLabel(for: historical))\n\(snippet)"
            }
            guard blocks.isEmpty == false else { return nil }

            if blocks.count == 1 {
                let sourceKind: ComposerSource.Kind = representative.message.isSentByUser
                    ? .pastReply
                    : .retrieved
                return ComposerSource(
                    kind: sourceKind,
                    label: relatedLabel(for: representative.message),
                    snippet: representative.snippet,
                    messageID: representative.message.id
                )
            }

            let firstDate = orderedMessages.first.map(dateLabel(for:)) ?? ""
            let lastDate = orderedMessages.last.map(dateLabel(for:)) ?? firstDate
            let dateRange = firstDate == lastDate ? firstDate : "\(firstDate) to \(lastDate)"
            return ComposerSource(
                kind: .retrieved,
                label: "related thread · \(subjectLabel(representative.message)) · \(dateRange)",
                snippet: blocks.joined(separator: "\n\n"),
                messageID: representative.message.id
            )
        }
    }

    private static func relatedCandidateCorpus(
        for message: Message,
        context: ModelContext,
        limits: Limits
    ) -> RelatedCandidateCorpus {
        let recent = recentRelatedCandidateMessages(
            for: message,
            context: context,
            limits: limits
        )
        let canonical = canonicalTagCandidateCorpus(
            for: message,
            context: context,
            limits: limits
        )
        var seen = Set<UUID>()
        let messages = (canonical.messages + recent).filter { seen.insert($0.id).inserted }
        return RelatedCandidateCorpus(
            messages: messages,
            canonicalEvidenceByMessageID: canonical.canonicalEvidenceByMessageID
        )
    }

    private static func recentRelatedCandidateMessages(
        for message: Message,
        context: ModelContext,
        limits: Limits
    ) -> [Message] {
        let sort = [
            SortDescriptor(\Message.receivedAt, order: .reverse),
            SortDescriptor(\Message.sentAt, order: .reverse),
            SortDescriptor(\Message.ingestedAt, order: .reverse)
        ]
        let accountID = message.accountID ?? message.account?.id
        var descriptor: FetchDescriptor<Message>
        if let accountID {
            descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { candidate in
                    candidate.accountID == accountID
                },
                sortBy: sort
            )
        } else {
            descriptor = FetchDescriptor<Message>(sortBy: sort)
        }
        descriptor.fetchLimit = limits.relatedScanLimit
        return ((try? context.fetch(descriptor)) ?? []).filter { !$0.isTrashed }
    }

    /// Finds existing canonical tags from a new-compose subject/brief and
    /// retrieves their account-scoped historical members without creating a
    /// tag, observation, membership, or draft-side assignment. Persisted tag
    /// vectors can refine the match when an embedder is already available;
    /// lexical aliases remain the deterministic, embedding-free floor.
    static func semanticIntentSources(
        accountID: UUID?,
        intentText: String,
        context: ModelContext,
        limit: Int = Limits.default.relatedMessages,
        embedder: (any EmbeddingProvider)? = nil
    ) -> [ComposerSource] {
        let intent = intentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard intent.isEmpty == false, limit > 0 else { return [] }
        let intentTerms = ComposerSourceRelevance.tokens(intent, maxTokens: 200)
        let intentNormalized = SemanticTagNormalizer.normalizedText(intent)
        let intentVector = embedder?.embed(intent)
        let promoted = SemanticTagLifecycle.promoted.rawValue
        let tags = ((try? context.fetch(FetchDescriptor(
            predicate: #Predicate<SemanticTag> { tag in
                tag.lifecycleRaw == promoted
            }
        ))) ?? [])

        let matches = tags.compactMap { tag -> (SemanticTag, Double)? in
            var best = lexicalIntentMatchScore(
                intentNormalized: intentNormalized,
                intentTerms: intentTerms,
                surface: tag.preferredDisplayName
            )
            for alias in tag.aliases {
                best = max(
                    best,
                    lexicalIntentMatchScore(
                        intentNormalized: intentNormalized,
                        intentTerms: intentTerms,
                        surface: alias.displayName
                    )
                )
                if let intentVector,
                   alias.embeddingVersion == embedder?.embeddingVersion,
                   let aliasVector = persistedAliasVector(alias)?.values,
                   let similarity = cosineSimilarity(intentVector, aliasVector),
                   similarity >= 0.80 {
                    best = max(best, Double(similarity) * 0.88)
                }
            }
            guard best >= 0.58 else { return nil }
            return (tag, best)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        .prefix(3)

        var seedsByMessageID: [UUID: SemanticIntentCandidateSeed] = [:]
        for (tag, tagMatchScore) in matches {
            let hasHardQualifier = tagHasHardQualifier(tag)
            for membership in canonicalMemberships(
                tagID: tag.id,
                accountID: accountID,
                context: context,
                limit: Limits.default.canonicalMembershipScanLimit
            ) {
                guard let candidate = membership.message,
                      candidate.isTrashed == false else { continue }
                let membershipWeight = canonicalMembershipWeight(membership)
                guard membershipWeight >= 0.20 else { continue }
                let lightweightOverlap = intentTerms
                    .intersection(lightweightIssueTerms(for: candidate))
                    .count
                let shortlistScore = tagMatchScore * 3.0
                    + membershipWeight * 1.6
                    + min(Double(lightweightOverlap) * 0.55, 3.3)
                    + (hasHardQualifier ? 0.8 : 0)
                let seed = SemanticIntentCandidateSeed(
                    message: candidate,
                    tagMatchScore: tagMatchScore,
                    membershipWeight: membershipWeight,
                    hasHardQualifier: hasHardQualifier,
                    shortlistScore: shortlistScore
                )
                if let existing = seedsByMessageID[candidate.id],
                   existing.shortlistScore >= shortlistScore {
                    continue
                }
                seedsByMessageID[candidate.id] = seed
            }
        }

        let shortlisted = seedsByMessageID.values.sorted {
            if $0.shortlistScore != $1.shortlistScore {
                return $0.shortlistScore > $1.shortlistScore
            }
            let leftDate = sourceDate(for: $0.message)
            let rightDate = sourceDate(for: $1.message)
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.message.id.uuidString < $1.message.id.uuidString
        }
        .prefix(Limits.default.canonicalEvaluationLimit)

        var bestByMessageID: [UUID: RelatedCandidate] = [:]
        for seed in shortlisted {
            let candidate = seed.message
            let candidateTerms = ComposerSourceRelevance.topicalTerms(for: candidate)
            let overlap = intentTerms.intersection(candidateTerms).count
            guard seed.hasHardQualifier || overlap > 0 else { continue }
            let score = seed.tagMatchScore * 3.0
                + seed.membershipWeight * 1.6
                + min(Double(overlap) * 0.55, 3.3)
            let fallback = ComposerSourceRelevance.messageText(
                for: candidate,
                bodyLimit: 3_200,
                attachmentLimit: 1_500
            )
            guard let snippet = relatedSnippet(
                of: candidate,
                fallbackText: fallback,
                attachmentLimit: Limits.default.snippetCharacters,
                anchorTerms: intentTerms.sorted()
            ) else { continue }
            let ranked = RelatedCandidate(message: candidate, score: score, snippet: snippet)
            bestByMessageID[candidate.id] = ranked
        }

        return bundledSemanticIntentSources(
            candidates: Array(bestByMessageID.values),
            limit: limit,
            anchorTerms: intentTerms.sorted()
        )
    }

    private static func lexicalIntentMatchScore(
        intentNormalized: String,
        intentTerms: Set<String>,
        surface: String
    ) -> Double {
        let normalizedSurface = SemanticTagNormalizer.normalizedText(surface)
        guard normalizedSurface.isEmpty == false else { return 0 }
        if intentNormalized.contains(normalizedSurface) { return 1 }
        let surfaceTerms = ComposerSourceRelevance.tokens(surface, maxTokens: 40)
        guard surfaceTerms.isEmpty == false else { return 0 }
        let overlap = intentTerms.intersection(surfaceTerms).count
        guard overlap > 0 else { return 0 }
        let coverage = Double(overlap) / Double(surfaceTerms.count)
        let jaccard = Double(overlap) / Double(intentTerms.union(surfaceTerms).count)
        return coverage * 0.72 + jaccard * 0.28
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return nil }
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { return nil }
        return dot / (sqrt(leftNorm) * sqrt(rightNorm))
    }

    private static func bundledSemanticIntentSources(
        candidates: [RelatedCandidate],
        limit: Int,
        anchorTerms: [String]
    ) -> [ComposerSource] {
        var grouped: [UUID: [RelatedCandidate]] = [:]
        for candidate in candidates {
            grouped[candidate.message.thread?.id ?? candidate.message.id, default: []]
                .append(candidate)
        }
        let rankedGroups = grouped.values.sorted { left, right in
            let leftScore = left.map(\.score).max() ?? 0
            let rightScore = right.map(\.score).max() ?? 0
            if leftScore != rightScore { return leftScore > rightScore }
            let leftDate = left.map { sourceDate(for: $0.message) }.max() ?? .distantPast
            let rightDate = right.map { sourceDate(for: $0.message) }.max() ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return (left.map(\.message.id.uuidString).min() ?? "")
                < (right.map(\.message.id.uuidString).min() ?? "")
        }

        return rankedGroups.prefix(limit).compactMap { group in
            guard let representative = group.sorted(by: {
                if $0.score != $1.score { return $0.score > $1.score }
                return sourceDate(for: $0.message) > sourceDate(for: $1.message)
            }).first else { return nil }
            let messages = (representative.message.thread?.messages ?? group.map(\.message))
                .filter { $0.isAutomatedOrBulk != true }
                .sorted { sourceDate(for: $0) < sourceDate(for: $1) }
            let blocks = messages.compactMap { historical -> String? in
                let fallback = ComposerSourceRelevance.messageText(
                    for: historical,
                    bodyLimit: 3_200,
                    attachmentLimit: 1_500
                )
                guard let snippet = relatedSnippet(
                    of: historical,
                    fallbackText: fallback,
                    attachmentLimit: Limits.default.snippetCharacters,
                    anchorTerms: anchorTerms
                ) else { return nil }
                let author = historical.isSentByUser
                    ? "you wrote"
                    : "\(historical.fromName ?? historical.fromAddress) wrote"
                return "\(author) · \(dateLabel(for: historical))\n\(snippet)"
            }
            guard blocks.isEmpty == false else { return nil }
            if blocks.count == 1 {
                return ComposerSource(
                    kind: representative.message.isSentByUser ? .pastReply : .retrieved,
                    label: relatedLabel(for: representative.message),
                    snippet: representative.snippet,
                    messageID: representative.message.id
                )
            }
            return ComposerSource(
                kind: .retrieved,
                label: "related tag · \(subjectLabel(representative.message))",
                snippet: blocks.joined(separator: "\n\n"),
                messageID: representative.message.id
            )
        }
    }

    private static func canonicalTagCandidateCorpus(
        for message: Message,
        context: ModelContext,
        limits: Limits
    ) -> RelatedCandidateCorpus {
        let anchors = canonicalTagAnchors(for: message)
        guard anchors.isEmpty == false else {
            return RelatedCandidateCorpus(messages: [], canonicalEvidenceByMessageID: [:])
        }

        let accountID = message.accountID ?? message.account?.id
        var messagesByID: [UUID: Message] = [:]
        var evidenceByMessageID: [UUID: CanonicalTagCandidateEvidence] = [:]

        for anchor in anchors {
            let accountMemberships = canonicalMemberships(
                tagID: anchor.tagID,
                accountID: accountID,
                context: context,
                limit: limits.canonicalMembershipScanLimit
            )
            let accountMembershipCount = Set(accountMemberships.map(\.logicalMessageKey)).count
            let hasHardQualifier = accountMemberships
                .compactMap(\.tag)
                .contains { tagHasHardQualifier($0) }

            for membership in accountMemberships {
                guard let candidate = membership.message,
                      candidate.id != message.id else { continue }
                let candidateWeight = canonicalMembershipWeight(membership)
                guard candidateWeight >= 0.20 else { continue }
                let candidateRoles = decodedSemanticTagRoles(membership.rolesJSON)
                var evidence = evidenceByMessageID[candidate.id] ?? CanonicalTagCandidateEvidence()
                evidence.exactAffinity = max(
                    evidence.exactAffinity,
                    anchor.weight * candidateWeight
                )
                evidence.matchingRoleCount = max(
                    evidence.matchingRoleCount,
                    anchor.roles.intersection(candidateRoles).count
                )
                evidence.matchingRoles.formUnion(anchor.roles.intersection(candidateRoles))
                evidence.accountMembershipCount = max(
                    evidence.accountMembershipCount,
                    accountMembershipCount
                )
                evidence.hasHardQualifier = evidence.hasHardQualifier || hasHardQualifier
                evidenceByMessageID[candidate.id] = evidence
                messagesByID[candidate.id] = candidate
            }
        }


        for relatedAnchor in relatedCanonicalTagAnchors(
            for: anchors,
            accountID: accountID,
            context: context,
            limits: limits
        ) {
            let memberships = canonicalMemberships(
                tagID: relatedAnchor.tagID,
                accountID: accountID,
                context: context,
                limit: limits.canonicalMembershipScanLimit
            )
            for membership in memberships {
                guard let candidate = membership.message,
                      candidate.id != message.id,
                      candidate.isTrashed == false else { continue }
                let candidateWeight = canonicalMembershipWeight(membership)
                guard candidateWeight >= 0.20 else { continue }
                let candidateRoles = decodedSemanticTagRoles(membership.rolesJSON)
                var evidence = evidenceByMessageID[candidate.id] ?? CanonicalTagCandidateEvidence()
                evidence.relatedAffinity = max(
                    evidence.relatedAffinity,
                    relatedAnchor.affinity * candidateWeight
                )
                evidence.matchingRoleCount = max(
                    evidence.matchingRoleCount,
                    relatedAnchor.roles.intersection(candidateRoles).count
                )
                evidence.matchingRoles.formUnion(
                    relatedAnchor.roles.intersection(candidateRoles)
                )
                evidenceByMessageID[candidate.id] = evidence
                messagesByID[candidate.id] = candidate
            }
        }

        let anchorIssueTerms = lightweightIssueTerms(for: message)
        let messages = messagesByID.values.sorted {
            let leftEvidence = evidenceByMessageID[$0.id] ?? CanonicalTagCandidateEvidence()
            let rightEvidence = evidenceByMessageID[$1.id] ?? CanonicalTagCandidateEvidence()
            let leftScore = canonicalShortlistScore(
                message: $0,
                evidence: leftEvidence,
                anchorIssueTerms: anchorIssueTerms
            )
            let rightScore = canonicalShortlistScore(
                message: $1,
                evidence: rightEvidence,
                anchorIssueTerms: anchorIssueTerms
            )
            if leftScore != rightScore { return leftScore > rightScore }
            let leftDate = sourceDate(for: $0)
            let rightDate = sourceDate(for: $1)
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id.uuidString < $1.id.uuidString
        }
        .prefix(max(0, limits.canonicalEvaluationLimit))
        .map { $0 }
        let retainedIDs = Set(messages.map(\.id))
        return RelatedCandidateCorpus(
            messages: messages,
            canonicalEvidenceByMessageID: evidenceByMessageID.filter {
                retainedIDs.contains($0.key)
            }
        )
    }

    private static func canonicalMemberships(
        tagID: UUID,
        accountID: UUID?,
        context: ModelContext,
        limit: Int
    ) -> [MessageSemanticTagMembership] {
        var descriptor = FetchDescriptor(
            predicate: #Predicate<MessageSemanticTagMembership> { membership in
                membership.tagID == tagID
            },
            sortBy: [
                SortDescriptor(\MessageSemanticTagMembership.score, order: .reverse),
                SortDescriptor(\MessageSemanticTagMembership.confidence, order: .reverse),
                SortDescriptor(\MessageSemanticTagMembership.reconciledAt, order: .reverse),
            ]
        )
        descriptor.fetchLimit = max(0, limit)
        return ((try? context.fetch(descriptor)) ?? []).filter { membership in
            guard let candidate = membership.message, candidate.isTrashed == false else {
                return false
            }
            guard let accountID else { return true }
            return (candidate.accountID ?? candidate.account?.id) == accountID
        }
    }

    private static func canonicalShortlistScore(
        message: Message,
        evidence: CanonicalTagCandidateEvidence,
        anchorIssueTerms: Set<String>
    ) -> Double {
        let issueOverlap = anchorIssueTerms.intersection(lightweightIssueTerms(for: message)).count
        return evidence.exactAffinity * 4
            + evidence.relatedAffinity * 2.2
            + Double(evidence.matchingRoleCount) * 1.6
            + min(Double(issueOverlap) * 0.8, 4.8)
            + (evidence.hasHardQualifier ? 1.2 : 0)
    }

    /// Cheap subject/summary issue terms for the pre-body-I/O shortlist.
    /// Canonical tag labels are removed because a tag cannot be its own
    /// independent corroboration.
    private static func lightweightIssueTerms(for message: Message) -> Set<String> {
        let text = [message.subject, message.analysis?.bodySummary ?? ""]
            .joined(separator: "\n")
        return ComposerSourceRelevance.tokens(text, maxTokens: 120)
            .subtracting(semanticTagTermTokens(for: message))
    }

    private static func independentIssueTerms(
        for message: Message,
        excluding selfProfile: ComposerSourceRelevance.SelfIdentityProfile
    ) -> Set<String> {
        ComposerSourceRelevance.topicalTerms(for: message, excluding: selfProfile)
            .subtracting(semanticTagTermTokens(for: message))
    }

    private static func semanticTagTermTokens(for message: Message) -> Set<String> {
        ComposerSourceRelevance.tokens(
            ComposerSourceRelevance.semanticAffinityTerms(of: message)
                .joined(separator: "\n"),
            maxTokens: 80
        )
    }

    private static func relatedCanonicalTagAnchors(
        for anchors: [CanonicalTagAnchor],
        accountID: UUID?,
        context: ModelContext,
        limits: Limits
    ) -> [RelatedCanonicalTagAnchor] {
        var relatedByTagID: [UUID: RelatedCanonicalTagAnchor] = [:]
        let activeTags = (try? context.fetch(FetchDescriptor<SemanticTag>())) ?? []
        let tagsByID = Dictionary(uniqueKeysWithValues: activeTags.map { ($0.id, $0) })
        let anchorIDs = Set(anchors.map(\.tagID))
        let anchorTags = anchors.compactMap { tagsByID[$0.tagID] }
        let accountCorpusCount = max(
            1,
            accountMessageCount(accountID: accountID, context: context)
        )
        var membershipCountByTagID: [UUID: Int] = [:]

        for anchor in anchors {
            guard let anchorTag = tagsByID[anchor.tagID],
                  anchorTag.lifecycle != .merged else { continue }
            let accountMemberships = canonicalMemberships(
                tagID: anchor.tagID,
                accountID: accountID,
                context: context,
                limit: limits.canonicalMembershipScanLimit
            )
            let anchorMessageCount = max(1, Set(accountMemberships.map(\.logicalMessageKey)).count)
            var cooccurringMessageKeys: [UUID: Set<String>] = [:]
            var cooccurringRoles: [UUID: Set<SemanticTagRole>] = [:]
            for membership in accountMemberships {
                guard let candidate = membership.message else { continue }
                for neighbor in candidate.semanticTagMemberships {
                    guard anchorIDs.contains(neighbor.tagID) == false,
                          canonicalMembershipWeight(neighbor) >= 0.20 else { continue }
                    cooccurringMessageKeys[neighbor.tagID, default: []]
                        .insert(membership.logicalMessageKey)
                    cooccurringRoles[neighbor.tagID, default: []]
                        .formUnion(decodedSemanticTagRoles(neighbor.rolesJSON))
                }
            }

            for candidateTag in activeTags where candidateTag.lifecycle == .promoted {
                guard anchorIDs.contains(candidateTag.id) == false,
                      anchorTags.allSatisfy({
                          qualifierSignaturesConflict($0, candidateTag) == false
                      }) else {
                    continue
                }
                let cooccurrenceCount = cooccurringMessageKeys[candidateTag.id]?.count ?? 0
                let conditionalCooccurrence = Double(cooccurrenceCount) / Double(anchorMessageCount)
                let semanticSimilarity = persistedTagSimilarity(anchorTag, candidateTag)
                var normalizedCooccurrence = 0.0
                var associationLift = 0.0
                if cooccurrenceCount >= 3, conditionalCooccurrence >= 0.20 {
                    let candidateMessageCount: Int
                    if let cached = membershipCountByTagID[candidateTag.id] {
                        candidateMessageCount = cached
                    } else {
                        candidateMessageCount = Set(canonicalMemberships(
                            tagID: candidateTag.id,
                            accountID: accountID,
                            context: context,
                            limit: limits.canonicalMembershipScanLimit
                        ).map(\.logicalMessageKey)).count
                        membershipCountByTagID[candidateTag.id] = candidateMessageCount
                    }
                    if candidateMessageCount > 0 {
                        normalizedCooccurrence = Double(cooccurrenceCount)
                            / sqrt(Double(anchorMessageCount * candidateMessageCount))
                        let candidateBaseRate = Double(candidateMessageCount)
                            / Double(accountCorpusCount)
                        associationLift = candidateBaseRate > 0
                            ? conditionalCooccurrence / candidateBaseRate
                            : 0
                    }
                }
                let cooccurrenceQualifies = cooccurrenceCount >= 3
                    && conditionalCooccurrence >= 0.20
                    && normalizedCooccurrence >= 0.20
                    && associationLift >= 1.20
                let semanticQualifies = semanticSimilarity.map { $0 >= 0.80 } == true
                guard cooccurrenceQualifies || semanticQualifies else { continue }

                let cooccurrenceStrength = cooccurrenceQualifies
                    ? min(1, max(conditionalCooccurrence, normalizedCooccurrence))
                    : 0
                let semanticStrength = semanticQualifies
                    ? Double(semanticSimilarity ?? 0)
                    : 0
                let affinity = anchor.weight * max(
                    cooccurrenceStrength * 0.72,
                    semanticStrength * 0.62
                )
                let related = RelatedCanonicalTagAnchor(
                    tagID: candidateTag.id,
                    affinity: affinity,
                    roles: cooccurringRoles[candidateTag.id] ?? []
                )
                if let existing = relatedByTagID[candidateTag.id],
                   existing.affinity >= related.affinity {
                    continue
                }
                relatedByTagID[candidateTag.id] = related
            }
        }

        return relatedByTagID.values.sorted {
            if $0.affinity != $1.affinity { return $0.affinity > $1.affinity }
            return $0.tagID.uuidString < $1.tagID.uuidString
        }
        .prefix(2)
        .map { $0 }
    }

    private static func accountMessageCount(
        accountID: UUID?,
        context: ModelContext
    ) -> Int {
        if let accountID {
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.accountID == accountID && message.trashedAt == nil
                }
            )
            return (try? context.fetchCount(descriptor)) ?? 0
        }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.trashedAt == nil
            }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private static func qualifierSignaturesConflict(
        _ lhs: SemanticTag,
        _ rhs: SemanticTag
    ) -> Bool {
        let lhsValues = decodedQualifierValues(lhs.qualifierSignatureJSON)
        let rhsValues = decodedQualifierValues(rhs.qualifierSignatureJSON)
        for kind in lhsValues.keys where rhsValues[kind] != nil {
            guard let left = lhsValues[kind],
                  let right = rhsValues[kind],
                  left.isEmpty == false,
                  right.isEmpty == false else { continue }
            if left.isDisjoint(with: right) { return true }
        }
        return false
    }

    private static func decodedQualifierValues(_ json: String) -> [String: Set<String>] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return values.mapValues(Set.init)
    }

    private static func persistedTagSimilarity(
        _ lhs: SemanticTag,
        _ rhs: SemanticTag
    ) -> Float? {
        let leftVectors = lhs.aliases.compactMap(persistedAliasVector)
        let rightVectors = rhs.aliases.compactMap(persistedAliasVector)
        var best: Float?
        for left in leftVectors {
            for right in rightVectors where left.version == right.version {
                guard let similarity = cosineSimilarity(left.values, right.values) else {
                    continue
                }
                if best == nil || similarity > best! { best = similarity }
            }
        }
        return best
    }

    private struct VersionedAliasVector {
        let version: String
        let values: [Float]
    }

    private static func persistedAliasVector(
        _ alias: SemanticTagAlias
    ) -> VersionedAliasVector? {
        guard let version = alias.embeddingVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            version.isEmpty == false,
            let data = alias.embeddingData,
            let values = try? JSONDecoder().decode([Float].self, from: data) else {
            return nil
        }
        return VersionedAliasVector(version: version, values: values)
    }

    private static func canonicalTagAnchors(for message: Message) -> [CanonicalTagAnchor] {
        var anchorsByID: [UUID: CanonicalTagAnchor] = [:]
        let evidenceMessages = contextualThreadMessages(for: message)
        for evidenceMessage in evidenceMessages {
            let threadWeight = evidenceMessage.id == message.id ? 1.0 : 0.72
            for membership in evidenceMessage.semanticTagMemberships {
                let weight = canonicalMembershipWeight(membership) * threadWeight
                guard weight >= 0.20 else { continue }
                let anchor = CanonicalTagAnchor(
                    tagID: membership.tagID,
                    weight: weight,
                    roles: decodedSemanticTagRoles(membership.rolesJSON)
                )
                if let existing = anchorsByID[membership.tagID], existing.weight >= weight {
                    continue
                }
                anchorsByID[membership.tagID] = anchor
            }

            guard let dimensions = ComposerSourceRelevance.dimensions(of: evidenceMessage) else {
                continue
            }
            for projection in SemanticTagProjectionPresentation.canonical(dimensions.semanticTags) {
                let weight = projection.weightedScore * threadWeight
                guard weight >= 0.20 else { continue }
                let anchor = CanonicalTagAnchor(
                    tagID: projection.tagID,
                    weight: weight,
                    roles: Set(projection.roles)
                )
                if let existing = anchorsByID[projection.tagID], existing.weight >= weight {
                    continue
                }
                anchorsByID[projection.tagID] = anchor
            }
        }
        return anchorsByID.values.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return $0.tagID.uuidString < $1.tagID.uuidString
        }
        .prefix(3)
        .map { $0 }
    }

    private static func canonicalMembershipWeight(
        _ membership: MessageSemanticTagMembership
    ) -> Double {
        // Ingestion stores the centrality multiplier in `score`; applying the
        // decoded centrality again would square the penalty and discard valid
        // mention/secondary evidence.
        return min(1, max(0, membership.score * membership.confidence))
    }

    private static func decodedSemanticTagRoles(_ json: String) -> Set<SemanticTagRole> {
        guard let data = json.data(using: .utf8),
              let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(rawValues.compactMap(SemanticTagRole.init(rawValue:)))
    }

    private static func tagHasHardQualifier(_ tag: SemanticTag) -> Bool {
        guard let data = tag.qualifierSignatureJSON.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return false
        }
        return values.values.contains { $0.isEmpty == false }
    }

    private struct RelatedAnchorEvidence {
        let selfProfile: ComposerSourceRelevance.SelfIdentityProfile
        let topicalTerms: Set<String>
        let issueTerms: Set<String>
        let subjectTerms: Set<String>
        let normalizedSubject: String
        let primaryCorrespondentTerms: Set<String>
        let semanticKeys: ComposerSourceRelevance.SemanticAffinityKeys
        let draftingAffinityKeys: Set<String>
        let correspondent: String
        let messageIDHeaders: Set<String>
        let referencedHeaders: Set<String>
        let distinctiveIdentifiers: Set<String>
        let referenceDate: Date
    }

    /// Shared hard gate for every cross-thread message lane: deterministic
    /// past replies, account-wide related candidates, and hybrid retrieval.
    /// Recipient, classification, account, and recency can rank a candidate only
    /// after a topic/project/identifier/semantic bridge makes it eligible.
    static func crossThreadRelevanceScores(
        for message: Message,
        candidates: [Message],
        context: ModelContext,
        storedAffinities: [UUID: ComposerRelatedAffinity] = [:],
        canonicalEvidenceByMessageID: [UUID: CanonicalTagCandidateEvidence] = [:],
        minimumScore: Double = Limits.default.relatedMinimumScore
    ) -> [UUID: Double] {
        let knownCustomCategoryKeys = CustomMailCategoryCatalog.allKeys(in: context)
        let anchor = relatedAnchorEvidence(
            for: message,
            context: context,
            knownCustomCategoryKeys: knownCustomCategoryKeys
        )
        var scores: [UUID: Double] = [:]
        for candidate in candidates where candidate.id != message.id {
            guard let score = relatedScore(
                candidate: candidate,
                anchor: anchor,
                storedAffinity: storedAffinities[candidate.id],
                canonicalEvidence: canonicalEvidenceByMessageID[candidate.id],
                knownCustomCategoryKeys: knownCustomCategoryKeys
            ), score >= minimumScore else {
                continue
            }
            scores[candidate.id] = score
        }
        return scores
    }

    private static func relatedAnchorEvidence(
        for message: Message,
        context: ModelContext,
        knownCustomCategoryKeys: Set<String>
    ) -> RelatedAnchorEvidence {
        let selfProfile = ComposerSourceRelevance.selfIdentityProfile(context: context)
        let evidenceMessages = contextualThreadMessages(for: message)
        var topicalTerms = Set<String>()
        var issueTerms = Set<String>()
        var subjectTerms = Set<String>()
        var tagKeys = Set<String>()
        var draftingAffinityKeys = Set<String>()
        var messageIDHeaders = Set<String>()
        var referencedHeaders = Set<String>()
        for evidenceMessage in evidenceMessages {
            topicalTerms.formUnion(ComposerSourceRelevance.topicalTerms(
                for: evidenceMessage,
                excluding: selfProfile
            ))
            issueTerms.formUnion(independentIssueTerms(
                for: evidenceMessage,
                excluding: selfProfile
            ))
            subjectTerms.formUnion(ComposerSourceRelevance.subjectTerms(
                for: evidenceMessage,
                excluding: selfProfile
            ))
            let semanticKeys = ComposerSourceRelevance.semanticAffinityKeys(of: evidenceMessage)
            tagKeys.formUnion(semanticKeys.tags)
            draftingAffinityKeys.formUnion(ComposerSourceRelevance.draftingAffinityKeys(
                of: evidenceMessage,
                knownCustomCategoryKeys: knownCustomCategoryKeys
            ))
            if let header = normalizedMessageHeader(evidenceMessage.messageIdHeader) {
                messageIDHeaders.insert(header)
            }
            referencedHeaders.formUnion(referencedMessageHeaders(of: evidenceMessage))
        }
        return RelatedAnchorEvidence(
            selfProfile: selfProfile,
            topicalTerms: topicalTerms,
            issueTerms: issueTerms,
            subjectTerms: subjectTerms,
            normalizedSubject: ThreadAssigner.normalizedSubject(message.subject),
            primaryCorrespondentTerms: ComposerSourceRelevance.primaryCorrespondentTerms(
                for: message,
                excluding: selfProfile
            ),
            semanticKeys: ComposerSourceRelevance.SemanticAffinityKeys(tags: tagKeys),
            draftingAffinityKeys: draftingAffinityKeys,
            correspondent: message.fromAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            messageIDHeaders: messageIDHeaders,
            referencedHeaders: referencedHeaders,
            distinctiveIdentifiers: ComposerSourceRelevance.distinctiveIdentifiers(in: issueTerms),
            referenceDate: sourceDate(for: message)
        )
    }

    private static func relatedScore(
        candidate: Message,
        anchor: RelatedAnchorEvidence,
        storedAffinity: ComposerRelatedAffinity?,
        canonicalEvidence: CanonicalTagCandidateEvidence?,
        knownCustomCategoryKeys: Set<String>
    ) -> Double? {
        let candidateTerms = ComposerSourceRelevance.topicalTerms(
            for: candidate,
            excluding: anchor.selfProfile
        )
        let candidateIssueTerms = independentIssueTerms(
            for: candidate,
            excluding: anchor.selfProfile
        )
        let candidateSubjectTerms = ComposerSourceRelevance.subjectTerms(
            for: candidate,
            excluding: anchor.selfProfile
        )
        let candidateSemanticKeys = ComposerSourceRelevance.semanticAffinityKeys(of: candidate)
        let identityOverlap = anchor.primaryCorrespondentTerms
            .intersection(candidateTerms)
            .filter(isSpecificIdentityBridgeToken)
            .count
        let topicalOverlap = anchor.issueTerms.intersection(candidateIssueTerms).count
        let subjectOverlap = anchor.subjectTerms.intersection(candidateSubjectTerms).count
        let sharedTags = anchor.semanticKeys.tags
            .intersection(candidateSemanticKeys.tags)
            .count
        let sharedDraftingFacets = anchor.draftingAffinityKeys
            .intersection(ComposerSourceRelevance.draftingAffinityKeys(
                of: candidate,
                knownCustomCategoryKeys: knownCustomCategoryKeys
            ))
            .count
        let sharedIdentifiers = anchor.distinctiveIdentifiers
            .intersection(ComposerSourceRelevance.distinctiveIdentifiers(in: candidateIssueTerms))
            .count

        let candidateSender = candidate.fromAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sameCorrespondent = !anchor.correspondent.isEmpty
            && candidateSender == anchor.correspondent
        let addressedToCurrent = candidate.isSentByUser
            && isAddressed(candidate, to: anchor.correspondent)
        let normalizedCandidateSubject = ThreadAssigner.normalizedSubject(candidate.subject)
        let exactSubject = !anchor.normalizedSubject.isEmpty
            && anchor.normalizedSubject == normalizedCandidateSubject
        let replyLinked = messagesAreReplyLinked(candidate: candidate, anchor: anchor)
        let subjectCoverage = overlapCoverage(
            overlap: subjectOverlap,
            leftCount: anchor.subjectTerms.count,
            rightCount: candidateSubjectTerms.count
        )
        let topicalCoverage = overlapCoverage(
            overlap: topicalOverlap,
            leftCount: anchor.issueTerms.count,
            rightCount: candidateIssueTerms.count
        )

        guard relatedCandidateHasSpecificBridge(
            replyLinked: replyLinked,
            sharedTags: sharedTags,
            canonicalEvidence: canonicalEvidence,
            sharedIdentifiers: sharedIdentifiers,
            identityOverlap: identityOverlap,
            exactSubject: exactSubject,
            subjectTermCount: min(anchor.subjectTerms.count, candidateSubjectTerms.count),
            subjectOverlap: subjectOverlap,
            subjectCoverage: subjectCoverage,
            topicalOverlap: topicalOverlap,
            topicalCoverage: topicalCoverage,
            sameCorrespondent: sameCorrespondent,
            addressedToCurrent: addressedToCurrent,
            storedAffinity: storedAffinity
        ) else {
            return nil
        }

        var score = 0.0
        if replyLinked { score += 4.0 }
        if let canonicalEvidence, canonicalEvidence.hasExactMatch {
            score += min(5.2, 2.8 + canonicalEvidence.exactAffinity * 1.8)
            score += min(1.8, Double(canonicalEvidence.matchingRoleCount) * 1.4)
            score += roleSensitiveFreshnessBonus(
                matchingRoles: canonicalEvidence.matchingRoles,
                candidateDate: sourceDate(for: candidate),
                referenceDate: anchor.referenceDate
            )
        } else if let canonicalEvidence, canonicalEvidence.relatedAffinity > 0 {
            score += min(3.4, 1.8 + canonicalEvidence.relatedAffinity * 1.8)
            score += min(1.4, Double(canonicalEvidence.matchingRoleCount) * 1.0)
            score += roleSensitiveFreshnessBonus(
                matchingRoles: canonicalEvidence.matchingRoles,
                candidateDate: sourceDate(for: candidate),
                referenceDate: anchor.referenceDate
            )
        } else {
            score += min(Double(sharedTags) * 3.2, 6.4)
        }
        score += min(Double(sharedIdentifiers) * 2.8, 5.6)
        score += min(Double(identityOverlap) * 1.35, 2.7)
        score += min(Double(subjectOverlap) * 0.7, 2.1)
        score += min(Double(topicalOverlap) * 0.35, 2.1)
        if topicalOverlap >= 5, topicalCoverage >= 0.35 { score += 1.0 }
        if exactSubject { score += 2.8 }
        if sameCorrespondent { score += 0.35 }
        if addressedToCurrent { score += 0.35 }
        score += Double(sharedDraftingFacets) * 0.15
        score += relatedStoredAffinityBonus(storedAffinity)
        return score
    }

    nonisolated static func roleSensitiveFreshnessBonus(
        matchingRoles: Set<SemanticTagRole>,
        candidateDate: Date,
        referenceDate: Date
    ) -> Double {
        guard matchingRoles.isEmpty == false else { return 0 }
        let ageDays = max(0, referenceDate.timeIntervalSince(candidateDate)) / 86_400
        let changingStateRoles: Set<SemanticTagRole> = [
            .request, .decision, .blocker, .update, .confirmation, .deadline,
            .scheduling, .status, .offer, .payment, .access,
        ]
        if matchingRoles.isDisjoint(with: changingStateRoles) == false {
            return 1.2 * exp(-ageDays / 180)
        }

        // Documents, people, vendors, and locations remain useful far longer;
        // recency can break a close tie but must not erase a more specific
        // stable reference merely because it is old.
        return 0.25 * exp(-ageDays / 1_825)
    }

    private static func relatedCandidateHasSpecificBridge(
        replyLinked: Bool,
        sharedTags: Int,
        canonicalEvidence: CanonicalTagCandidateEvidence?,
        sharedIdentifiers: Int,
        identityOverlap: Int,
        exactSubject: Bool,
        subjectTermCount: Int,
        subjectOverlap: Int,
        subjectCoverage: Double,
        topicalOverlap: Int,
        topicalCoverage: Double,
        sameCorrespondent: Bool,
        addressedToCurrent: Bool,
        storedAffinity: ComposerRelatedAffinity?
    ) -> Bool {
        if replyLinked || sharedIdentifiers > 0 {
            return true
        }
        if let canonicalEvidence,
           canonicalEvidence.exactMatchQualifies(
               topicalOverlap: topicalOverlap,
               sharedIdentifiers: sharedIdentifiers
           ) {
            return true
        }
        if let canonicalEvidence,
           canonicalEvidence.relatedMatchQualifies(
               topicalOverlap: topicalOverlap,
               sharedIdentifiers: sharedIdentifiers,
               hasStrongStoredAffinity: relatedStoredAffinityIsStrong(storedAffinity)
           ) {
            return true
        }
        if canonicalEvidence == nil, sharedTags > 0 {
            return true
        }
        let hasStrongStoredAffinity = relatedStoredAffinityIsStrong(storedAffinity)
        // Stored vector affinity can corroborate one concrete identity/topic
        // token, but semantic similarity alone is too broad to admit mail.
        // An explicit mention of the primary correspondent is a meaningful
        // entity bridge. Merely sending to/from that address is not.
        if identityOverlap >= 2 || (identityOverlap == 1 && hasStrongStoredAffinity) {
            return true
        }

        let hasCorrespondentConnection = sameCorrespondent || addressedToCurrent
        if exactSubject,
           hasCorrespondentConnection,
           subjectTermCount >= 2 {
            return true
        }
        if sharedTags > 0,
           topicalOverlap >= (hasStrongStoredAffinity ? 1 : 2),
           (hasCorrespondentConnection || storedAffinity?.sharesMeaningCluster == true) {
            return true
        }
        if subjectOverlap >= 3, subjectCoverage >= 0.50 {
            return true
        }
        return topicalOverlap >= 5 && topicalCoverage >= 0.35
    }

    private static func overlapCoverage(
        overlap: Int,
        leftCount: Int,
        rightCount: Int
    ) -> Double {
        let denominator = min(leftCount, rightCount)
        guard overlap > 0, denominator > 0 else { return 0 }
        return Double(overlap) / Double(denominator)
    }

    private static func messagesAreReplyLinked(
        candidate: Message,
        anchor: RelatedAnchorEvidence
    ) -> Bool {
        let candidateHeader = normalizedMessageHeader(candidate.messageIdHeader)
        let candidateReferences = referencedMessageHeaders(of: candidate)
        if candidateReferences.isDisjoint(with: anchor.messageIDHeaders) == false {
            return true
        }
        if let candidateHeader,
           anchor.referencedHeaders.contains(candidateHeader) {
            return true
        }
        return false
    }

    private static func referencedMessageHeaders(of message: Message) -> Set<String> {
        var headers = Set<String>()
        if let inReplyTo = normalizedMessageHeader(message.inReplyTo) {
            headers.insert(inReplyTo)
        }
        if let references = message.referencesChain {
            for token in references.split(whereSeparator: \.isWhitespace) {
                if let header = normalizedMessageHeader(String(token)) {
                    headers.insert(header)
                }
            }
        }
        return headers
    }

    private static func normalizedMessageHeader(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func relatedStoredAffinityBonus(_ affinity: ComposerRelatedAffinity?) -> Double {
        guard let affinity else { return 0 }
        var bonus = 0.0
        if let similarity = affinity.semanticSimilarity, similarity.isFinite {
            let clamped = min(max(similarity, 0), 1)
            if clamped >= 0.84 {
                bonus += min(3.4, 3.0 + ((clamped - 0.84) * 4.0))
            } else if clamped >= 0.70 {
                bonus += min(1.4, (clamped - 0.70) * 10.0)
            }
        }
        if affinity.sharesMeaningCluster {
            bonus += 0.6
        }
        return min(bonus, 3.6)
    }

    private static func relatedStoredAffinityIsStrong(_ affinity: ComposerRelatedAffinity?) -> Bool {
        guard let affinity else { return false }
        return affinity.semanticSimilarity.map { $0.isFinite && $0 >= 0.84 } == true
    }

    private static func isSpecificIdentityBridgeToken(_ token: String) -> Bool {
        let normalized = token.lowercased()
        guard genericIdentityBridgeTokens.contains(normalized) == false else {
            return false
        }
        return normalized.count >= 3 || normalized.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    private static let genericIdentityBridgeTokens: Set<String> = [
        "ac", "admin", "administration", "co", "college", "com",
        "department", "edu", "email", "faculty", "gov", "group", "jp",
        "mail", "net", "office", "org", "school", "service", "services",
        "support", "team", "uk", "unit", "university", "www",
        // Freemail and carrier domains: sharing a mail provider is not an
        // identity bridge between two messages.
        "aol", "biglobe", "daum", "docomo", "ezweb", "fastmail", "foxmail",
        "gmail", "gmx", "googlemail", "hanmail", "hotmail", "icloud", "live",
        "msn", "naver", "nifty", "ocn", "outlook", "proton", "protonmail",
        "sina", "softbank", "yahoo", "yandex", "ymail", "zoho", "126", "163"
    ]

    private static func relatedSnippet(
        of message: Message,
        fallbackText: String,
        attachmentLimit: Int,
        anchorTerms: [String]
    ) -> String? {
        var parts: [String] = []
        if let body = selectedBodySnippet(of: message, anchorTerms: anchorTerms) {
            parts.append(body)
        }
        for attachment in message.attachments.prefix(2) {
            guard let path = attachment.extractedTextPath,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let selected = passageSelector.select(from: text, anchorTerms: anchorTerms)
            guard !selected.isEmpty else { continue }
            parts.append("Attachment \(attachment.filename) — relevant extracted passages: \(selected)")
        }
        if parts.isEmpty {
            if let fallback = OriginalMessageText.cleaned(from: fallbackText) {
                let selected = passageSelector.select(
                    from: fallback,
                    anchorTerms: anchorTerms
                )
                if selected.isEmpty == false {
                    parts.append(selected)
                }
            }
        }
        let snippet = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }

    /// Direction-aware label for a message surfaced as evidence: the user's
    /// own messages render as "you → <recipient>", inbound ones as
    /// "related · <sender>". Shared with the retrieval lane
    /// (`DraftGenerationOrchestrator.retrievalSource`) so every
    /// message-backed source states who wrote it — the interview and
    /// generation prompts resolve each snippet's "I"/"you" from this
    /// attribution.
    static func relatedLabel(for message: Message) -> String {
        let subject = subjectLabel(message)
        let date = dateLabel(for: message)
        if message.isSentByUser {
            return "you → \(recipientSummary(of: message)) · \(subject) · \(date)"
        }
        let sender = message.fromName ?? message.fromAddress
        return "related · \(sender) · \(subject) · \(date)"
    }

    private static func recipientSummary(of message: Message) -> String {
        let recipients = message.participants
            .filter { $0.role == .to || $0.role == .cc }
            .compactMap { link -> String? in
                guard let participant = link.participant else { return nil }
                return participant.displayName?.isEmpty == false
                    ? participant.displayName
                    : participant.emailAddress
            }
        return recipients.first ?? "recipient"
    }

    /// Counts how many of the user's sent replies were addressed to this
    /// message's correspondent — the per-correspondent training basis surfaced
    /// in the Composer's personalization strip. Uses the same address match as
    /// `pastReplySources` but a far larger newest-first scan bound than the
    /// 3-snippet lookup needs (`pastReplySources` stops after 3; an honest
    /// basis count should not), so the strip rarely under-reports. The scan is
    /// still bounded to stay cheap on 100k-message stores — the result is the
    /// number of matches within the `scanLimit` most recent sent messages.
    public static func correspondentReplyCount(
        for message: Message,
        context: ModelContext,
        scanLimit: Int = 3000
    ) -> Int {
        let correspondent = message.fromAddress.lowercased()
        guard !correspondent.isEmpty else { return 0 }

        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { msg in
                msg.isSentByUser == true && msg.trashedAt == nil
            },
            sortBy: [
                SortDescriptor(\Message.sentAt, order: .reverse),
                SortDescriptor(\Message.ingestedAt, order: .reverse)
            ]
        )
        descriptor.fetchLimit = scanLimit
        let sent = (try? context.fetch(descriptor)) ?? []
        return sent.reduce(0) { count, candidate in
            isAddressed(candidate, to: correspondent) ? count + 1 : count
        }
    }

    // MARK: - Memory notes

    private static func memorySources(
        for message: Message,
        context: ModelContext,
        limits: Limits,
        embedder: (any EmbeddingProvider)? = nil
    ) -> [ComposerSource] {
        AccountMemoryDraftSelector.memoryNotes(for: message, context: context, embedder: embedder)
            .prefix(limits.memoryNotes)
            .map { note in
                // The interview's known-context digest renders memory through
                // the shared helper so its reliability tags read identically to
                // the draft prompts. The label stays the dimension label the
                // Composer UI shows; only the prompt-facing snippet carries the
                // tags.
                ComposerSource(
                    kind: .memory,
                    label: note.dimensionLabel,
                    snippet: MemoryNoteRendering.line(for: note),
                    memoryUsePolicy: note.usePolicyRaw
                )
            }
    }

    // MARK: - Attachments

    /// Hands each attachment's full extracted text to `ComposerContextPacker`
    /// rather than pre-cutting it to a fixed character count — a blind prefix
    /// cut has no idea whether the model has 500 spare tokens or 20,000, and
    /// silently discards whatever came after it even when there was room.
    /// `ComposerPassageSelector` (inside the packer) chunks and keeps the
    /// most anchor-relevant excerpt when a source doesn't fit; that's the
    /// same mechanism `threadSources`/`selectedBodySnippet` already rely on
    /// for message bodies.
    private static func attachmentSources(
        for message: Message,
        limits: Limits
    ) -> [ComposerSource] {
        message.attachments
            .compactMap { attachment -> ComposerSource? in
                guard let path = attachment.extractedTextPath,
                      let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return nil
                }
                let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !snippet.isEmpty else { return nil }
                return ComposerSource(
                    kind: .attachment,
                    label: attachment.filename,
                    snippet: snippet,
                    messageID: message.id
                )
            }
            .prefix(limits.attachments)
            .map { $0 }
    }

    // MARK: - Dates and web links

    private static func calendarSources(
        for message: Message,
        limits: Limits,
        now: Date,
        availabilityProvider: ComposerCalendarAvailabilityProvider?,
        availabilityEnabled: Bool
    ) -> [ComposerSource] {
        var sources: [ComposerSource] = []
        let facts = ComposerSourceRelevance.calendarFacts(for: message)
        if facts.isEmpty == false {
            let snippet = facts.prefix(8).joined(separator: "\n")
            sources.append(ComposerSource(
                kind: .calendar,
                label: "Dates and deadlines",
                snippet: snippet,
                messageID: message.id
            ))
        }

        // The availability snapshot is the only part that reads Calendar.app;
        // the dates-and-deadlines facts above come from the message itself and
        // survive the Settings → Sources Calendar toggle.
        if availabilityEnabled,
           let availability = calendarAvailabilitySource(
            for: message,
            limits: limits,
            now: now,
            provider: availabilityProvider ?? ComposerEventKitCalendarAvailabilityProvider.snapshot(interval:limit:)
        ) {
            sources.append(availability)
        }
        return sources
    }

    private static func calendarAvailabilitySource(
        for message: Message,
        limits: Limits,
        now: Date,
        provider: ComposerCalendarAvailabilityProvider
    ) -> ComposerSource? {
        guard limits.calendarEvents > 0,
              calendarAvailabilityApplies(to: message, now: now) else { return nil }
        let interval = calendarAvailabilityInterval(
            for: message,
            now: now,
            lookaheadDays: limits.calendarLookaheadDays,
            fallbackLookaheadDays: limits.calendarFallbackLookaheadDays
        )
        let snapshot = provider(interval, limits.calendarEvents)
        let range = calendarRangeLabel(interval)
        let snippet: String
        switch snapshot {
        case .available(let events):
            let availabilityEvents = events.filter { $0.availability != .free }
            if availabilityEvents.isEmpty {
                snippet = """
                Availability window: \(range)
                No busy or tentative calendar events found in this window.
                """
            } else {
                let eventLines = availabilityEvents.prefix(limits.calendarEvents).map(calendarAvailabilityBlockLine)
                snippet = """
                Availability window: \(range)
                Calendar availability blocks:
                \(eventLines.map { "- \($0)" }.joined(separator: "\n"))
                Event titles, calendar names, and locations are omitted from this automatic availability source.
                """
            }
        case .unavailable(let reason):
            snippet = """
            Availability window: \(range)
            Calendar availability could not be checked. \(reason)
            Do not claim the user is free or busy from calendar data.
            """
        }
        return ComposerSource(
            kind: .calendar,
            label: "Calendar availability · \(range)",
            snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines),
            messageID: message.id
        )
    }

    private static func calendarAvailabilityApplies(to message: Message, now: Date) -> Bool {
        var textParts = [
            message.subject,
            message.analysis?.bodySummary ?? "",
            ComposerSourceRelevance.messageText(for: message, bodyLimit: 3_000, attachmentLimit: 600)
        ]
        if let verdict = ComposerSourceRelevance.triageVerdict(of: message),
           verdict.isActionable,
           let action = verdict.action,
           action.kind == .scheduleMeeting {
            textParts.append(action.summary)
            textParts.append(contentsOf: action.decisionInputs)
        }
        let text = textParts.joined(separator: "\n")
        if let dimensions = ComposerSourceRelevance.dimensions(of: message) {
            let dimensionText = (
                ComposerSourceRelevance.legacyTaskRequirements(of: message, dimensions: dimensions)
                    .flatMap { [$0.taskType, $0.actionObject ?? "", $0.dueCandidate ?? ""] }
                    + ComposerSourceRelevance.semanticTagDisplayNames(in: dimensions)
            )
            .joined(separator: "\n")
            let hasDateOrTime = hasCalendarDateOrTimeEvidence(
                for: message,
                now: now,
                additionalText: dimensionText
            )
            if containsSchedulingCue(dimensionText, hasDateOrTime: hasDateOrTime) { return true }
        }

        let hasDateOrTime = hasCalendarDateOrTimeEvidence(for: message, now: now, additionalText: text)
        return containsSchedulingCue(text, hasDateOrTime: hasDateOrTime)
    }

    private static func containsSchedulingCue(_ text: String, hasDateOrTime: Bool) -> Bool {
        let lower = text.lowercased()
        if matchesAnyPattern(
            in: lower,
            patterns: [
                #"\b(are|were|would|could|can)\s+(you|we)\s+(be\s+)?(free|available)\b"#,
                #"\b(when|what\s+time)\s+(are|would|could|can)\s+(you|we)\s+(be\s+)?(free|available)\b"#,
                #"\b(your|my|our)\s+availability\b"#,
                #"\bavailability\s+(for|to)\s+(a\s+|the\s+)?(meeting|call|appointment|chat|conversation|discussion)\b"#,
                #"\bavailable\s+to\s+(meet|talk|chat|call)\b"#,
                #"\bavailable\s+for\s+(a\s+|the\s+)?(meeting|call|appointment|chat|conversation|discussion)\b"#,
                #"\bfree\s*/\s*busy\b"#,
                #"\bfree\s+or\s+busy\b"#,
                #"\bdo\s+you\s+have\s+time\b"#,
                #"\b(find|choose|pick)\s+(a\s+)?time\b"#,
                #"\btime\s+slots?\b"#,
                #"\bcalendar\s+(invite|invitation|availability)\b"#,
                #"\b(put|get|add)\b.{0,40}\b(on|to)\s+(the\s+|your\s+|my\s+|our\s+)?calendar\b"#,
                #"\bwhen\s+(can|could|should)\s+(we|you)\s+(meet|talk|chat|call)\b"#,
                #"\b(can|could|shall|should)\s+we\s+(meet|talk|chat)\b"#,
                #"\b(can|could|shall|should)\s+we\s+(have|do)\s+(a\s+)?call\b"#,
                #"\b(can|could|would)\s+you\s+(meet|talk|chat|join)\b"#,
                #"\b(schedule|reschedule|arrange|set\s+up|book)\s+(a\s+|the\s+)?(meeting|call|appointment|time|chat)\b"#
            ]
        ) {
            return true
        }

        guard hasDateOrTime else { return false }
        return matchesAnyPattern(
            in: lower,
            patterns: [
                #"\bavailable\s+(on|at|tomorrow|today|tonight|this|next)\b"#,
                #"\b(does|would|will)\s+(that|this)\s+work\b"#,
                #"\bworks?\s+for\s+you\b"#,
                #"\b(schedule|scheduling|reschedule|rescheduling|arrange|book|set\s+up)\b"#,
                #"\b(meet|talk|chat|call)\s+(on|at|around|before|after)\b"#,
                #"\b(meeting|appointment|call)\s+(on|at|around)\b"#
            ]
        )
    }

    private static func matchesAnyPattern(in lowercasedText: String, patterns: [String]) -> Bool {
        let range = NSRange(location: 0, length: (lowercasedText as NSString).length)
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: lowercasedText, options: [], range: range) != nil
        }
    }

    private static func hasCalendarDateOrTimeEvidence(
        for message: Message,
        now: Date,
        additionalText: String
    ) -> Bool {
        !calendarDateCandidates(for: message, now: now).isEmpty || containsRelativeTimeCue(additionalText)
    }

    private static func containsRelativeTimeCue(_ text: String) -> Bool {
        let lower = text.lowercased()
        return matchesAnyPattern(
            in: lower,
            patterns: [
                #"\b(today|tomorrow|tonight)\b"#,
                #"\b(this|next)\s+(morning|afternoon|evening|week|month)\b"#,
                #"\b(this|next)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
                #"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+(morning|afternoon|evening|night)?\b"#,
                #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b"#
            ]
        )
    }

    private static func calendarAvailabilityInterval(
        for message: Message,
        now: Date,
        lookaheadDays: Int,
        fallbackLookaheadDays: Int
    ) -> DateInterval {
        let calendar = Calendar.current
        let defaultStart = calendar.startOfDay(for: now)
        let defaultEnd = calendar.date(
            byAdding: .day,
            value: max(1, fallbackLookaheadDays),
            to: defaultStart
        ) ?? now.addingTimeInterval(TimeInterval(max(1, fallbackLookaheadDays)) * 86_400)

        let dates = calendarDateCandidates(for: message, now: now)
            .filter { $0 >= calendar.date(byAdding: .day, value: -1, to: defaultStart) ?? defaultStart }
        guard let earliest = dates.min(),
              let latest = dates.max() else {
            return DateInterval(start: defaultStart, end: defaultEnd)
        }

        let start = calendar.startOfDay(for: earliest)
        let nextDayAfterLatest = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: latest)
        ) ?? latest.addingTimeInterval(86_400)
        let cappedEnd = min(
            nextDayAfterLatest,
            calendar.date(byAdding: .day, value: max(1, lookaheadDays), to: start) ?? nextDayAfterLatest
        )
        return DateInterval(start: start, end: max(cappedEnd, start.addingTimeInterval(3_600)))
    }

    private static func calendarDateCandidates(for message: Message, now: Date) -> [Date] {
        var texts: [String] = [
            message.subject,
            message.analysis?.bodySummary ?? "",
            ComposerSourceRelevance.messageText(for: message, bodyLimit: 3_000, attachmentLimit: 600)
        ]
        if let dimensions = ComposerSourceRelevance.dimensions(of: message) {
            texts.append(contentsOf: dimensions.deadlines.compactMap(\.displayText))
            texts.append(contentsOf: ComposerSourceRelevance
                .legacyTaskRequirements(of: message, dimensions: dimensions)
                .compactMap(\.dueCandidate))
        }
        if let verdict = ComposerSourceRelevance.triageVerdict(of: message) {
            texts.append(contentsOf: verdict.deadlineCandidates.compactMap(\.displayText))
            if let action = verdict.action {
                texts.append(action.summary)
                texts.append(contentsOf: action.decisionInputs)
            }
            if let acknowledgement = verdict.acknowledgement {
                texts.append(acknowledgement.summary)
                texts.append(contentsOf: acknowledgement.materialFacts)
            }
        }

        let text = texts.joined(separator: "\n")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }
        let nsText = text as NSString
        return detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            .compactMap(\.date)
            .filter { $0 >= now.addingTimeInterval(-86_400) }
    }

    private static func calendarAvailabilityBlockLine(_ event: ComposerCalendarAvailabilityEvent) -> String {
        let status = calendarAvailabilityLabel(event.availability)
        let when: String
        if event.isAllDay {
            when = "\(calendarDayFormatter.string(from: event.startDate)) (\(status) all day)"
        } else {
            when = "\(calendarDayTimeFormatter.string(from: event.startDate))-\(calendarTimeFormatter.string(from: event.endDate)) (\(status))"
        }
        return when
    }

    private static func calendarAvailabilityLabel(_ availability: ComposerCalendarAvailabilityStatus) -> String {
        switch availability {
        case .busy:
            return "busy"
        case .free:
            return "free"
        case .tentative:
            return "tentative"
        case .unavailable:
            return "unavailable"
        }
    }

    private static func calendarRangeLabel(_ interval: DateInterval) -> String {
        let displayEnd = max(interval.start, interval.end.addingTimeInterval(-1))
        return "\(calendarDayFormatter.string(from: interval.start)) to \(calendarDayFormatter.string(from: displayEnd))"
    }

    private static let calendarDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let calendarDayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    private static let calendarTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func websiteSources(
        for message: Message,
        contextSources: [ComposerSource],
        context: ModelContext,
        limits: Limits
    ) -> [ComposerSource] {
        guard limits.websites > 0 else { return [] }
        let texts = websiteSourceTexts(
            for: message,
            contextSources: contextSources,
            context: context
        )
        guard !texts.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var seen = Set<String>()
        var sources: [ComposerSource] = []
        sourceLoop: for sourceText in texts {
            let nsText = sourceText.text as NSString
            let matches = detector.matches(
                in: sourceText.text,
                options: [],
                range: NSRange(location: 0, length: nsText.length)
            )
            for match in matches {
                guard sources.count < limits.websites,
                      let url = match.url,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }
                let normalized = normalizedURLString(url)
                guard seen.insert(normalized).inserted else { continue }
                let context = contextSnippet(in: nsText, around: match.range, limit: 320)
                let snippet = [
                    "URL: \(normalized)",
                    "Mentioned in: \(sourceText.label)",
                    context.isEmpty ? nil : "Context: \(context)"
                ]
                .compactMap { $0 }
                .joined(separator: "\n")
                sources.append(ComposerSource(
                    kind: .website,
                    label: websiteLabel(for: url),
                    snippet: snippet,
                    messageID: sourceText.messageID,
                    filePath: normalized
                ))
                if sources.count >= limits.websites { break sourceLoop }
            }
        }
        return sources
    }

    private struct WebsiteSourceText {
        let text: String
        let label: String
        let messageID: UUID?
    }

    private static func websiteSourceTexts(
        for message: Message,
        contextSources: [ComposerSource],
        context: ModelContext
    ) -> [WebsiteSourceText] {
        var texts: [WebsiteSourceText] = []
        let incomingBody = ComposerSourceRelevance.cleanedBodyText(for: message).map {
            String($0.prefix(6_000))
        } ?? ""
        let incomingText = [
            message.subject,
            incomingBody
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        if !incomingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.append(WebsiteSourceText(
                text: incomingText,
                label: "incoming message",
                messageID: message.id
            ))
        }

        for source in contextSources {
            switch source.kind {
            case .thread, .pastReply, .retrieved:
                guard let messageID = source.messageID,
                      let backingMessage = sourceMessage(id: messageID, context: context) else {
                    continue
                }
                let body = ComposerSourceRelevance.cleanedBodyText(for: backingMessage).map {
                    String($0.prefix(6_000))
                } ?? ""
                let text = [
                    backingMessage.subject,
                    body
                ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                texts.append(WebsiteSourceText(
                    text: text,
                    label: source.label,
                    messageID: source.messageID
                ))
            default:
                continue
            }
        }
        return texts
    }

    private static func sourceMessage(id: UUID, context: ModelContext) -> Message? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == id
            }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first.flatMap { $0.isTrashed ? nil : $0 }
    }

    private static func normalizedURLString(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: ".,);]>\n\t "))
    }

    private static func websiteLabel(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return host }
        return "\(host)/\(path)"
    }

    private static func contextSnippet(in text: NSString, around range: NSRange, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let half = max(20, limit / 2)
        let start = max(0, range.location - half)
        let end = min(text.length, range.location + range.length + half)
        guard end > start else { return "" }
        return text.substring(with: NSRange(location: start, length: end - start))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static let passageSelector = ComposerPassageSelector()

    private static func selectedBodySnippet(
        of message: Message,
        anchorTerms: [String]
    ) -> String? {
        guard let path = message.bodyTextPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let cleaned = OriginalMessageText.cleaned(from: text) else {
            return nil
        }
        let snippet = passageSelector.select(
            from: cleaned,
            anchorTerms: anchorTerms
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }

    private static func compactLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func subjectLabel(_ message: Message) -> String {
        message.subject.isEmpty ? "(no subject)" : message.subject
    }

    private static let sourceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static func dateLabel(for message: Message) -> String {
        sourceDateFormatter.string(from: sourceDate(for: message))
    }

    private static func sourceDate(for message: Message) -> Date {
        message.receivedAt ?? message.sentAt ?? message.ingestedAt
    }
}
