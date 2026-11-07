import CryptoKit
import Foundation
import OhiaCore
import OhiaML

/// Builds the `ProjectSummaryInput` consumed by `ProjectSummaryService` from a
/// `ProjectRow` and the per-message rows the Projects snapshot already holds.
///
/// A project can hold thousands of messages, so this never feeds raw bodies.
/// It samples a timeline-representative subset — the origin, the most recent
/// activity, and every obligation- or deadline-bearing message — capped at
/// `ProjectSummaryPromptBuilder.maxDigests`, and uses each message's stored
/// one-line summary (or its `bodySummary`) as the excerpt. The full project
/// size still rides along as `totalMessageCount` so the prompt knows the
/// sample is a sample.
enum ProjectSummaryInputBuilder {
    /// `targetID` namespace shared with `citationTargetMessageID(_:)` so the
    /// hover pane can map a `[N]` citation back to the message it cites.
    private static let messageTargetPrefix = "message:"

    /// Decodes a citation's `targetID` back into a message UUID. Returns `nil`
    /// for non-message targets or malformed ids.
    static func citationTargetMessageID(_ targetID: String?) -> UUID? {
        guard let targetID, targetID.hasPrefix(messageTargetPrefix) else { return nil }
        return UUID(uuidString: String(targetID.dropFirst(messageTargetPrefix.count)))
    }

    /// Stable cache/request identity for one committed manual-project
    /// generation. Display filters never participate: a configuration edit or
    /// any membership-set change gets a new key, while message ordering does
    /// not.
    static func requestKey(for row: ProjectRow) -> String {
        let members = row.messageIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
        let components = [
            row.projectID.uuidString.lowercased(),
            String(row.configurationRevision),
        ] + members
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(framed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "manual-project-summary:\(row.projectID.uuidString.lowercased()):\(digest)"
    }

    static func build(
        row: ProjectRow,
        messageInputs: [UUID: ProjectMessageInput],
        summaryByMessageId: [String: String],
        userIdentity: SummarizationUserIdentity?
    ) -> ProjectSummaryInput {
        // Resolve every committed project message from the structural project
        // snapshot. The top-bar display filter controls visible cards only and
        // must not narrow the user-triggered project briefing.
        var resolved: [(id: UUID, input: ProjectMessageInput)] = []
        resolved.reserveCapacity(row.messageIDs.count)
        for id in row.messageIDs {
            if let input = messageInputs[id] {
                resolved.append((id, input))
            }
        }
        resolved.sort { chronology($0.input.date, $1.input.date, $0.id, $1.id) }

        // Per-message obligation labels (open asks) and deadline flags.
        var obligationLabelsByMessage: [UUID: [String]] = [:]
        for obligation in row.obligations {
            obligationLabelsByMessage[obligation.messageID, default: []].append(obligationKindLabel(obligation.kind))
        }
        let deadlineMessageIDs = Set(row.deadlineTicks.map(\.messageID))

        let priorityIDs = Set(row.obligations.map(\.messageID)).union(deadlineMessageIDs)
        let selectedIDs = selectSampleIDs(
            ordered: resolved.map(\.id),
            priority: priorityIDs,
            limit: ProjectSummaryPromptBuilder.maxDigests
        )
        let inputByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0.input) })

        let digests: [ProjectSummaryMessageDigest] = selectedIDs.compactMap { id in
            guard let input = inputByID[id] else { return nil }
            let excerpt = collapse(summaryByMessageId[id.uuidString] ?? input.bodySummary ?? "")
            return ProjectSummaryMessageDigest(
                role: input.isSentByUser ? "outgoing" : "incoming",
                senderName: senderDisplay(input: input),
                subject: input.subject,
                excerpt: excerpt,
                receivedAt: input.date,
                recipients: recipients(input: input),
                obligationLabels: obligationLabelsByMessage[id] ?? [],
                isDeadlineBearing: deadlineMessageIDs.contains(id),
                citationTargetID: messageTargetPrefix + id.uuidString
            )
        }

        let obligations: [ProjectSummaryObligation] = row.obligations.map { obligation in
            let subject = inputByID[obligation.messageID]?.subject
            let summary = nonEmpty(obligation.summary) ?? nonEmpty(subject) ?? "Open item"
            return ProjectSummaryObligation(
                kindLabel: obligationKindLabel(obligation.kind),
                summary: summary,
                openedAt: obligation.openedAt,
                citationTargetID: messageTargetPrefix + obligation.messageID.uuidString
            )
        }

        let deadlines: [ProjectSummaryDeadline] = row.deadlineTicks.map { tick in
            ProjectSummaryDeadline(
                label: nonEmpty(tick.type) ?? "deadline",
                date: tick.date,
                evidenceText: collapse(tick.evidenceText),
                citationTargetID: messageTargetPrefix + tick.messageID.uuidString
            )
        }

        let participants: [ProjectSummaryParticipant] = row.participants
            .sorted { $0.messageCount > $1.messageCount }
            .prefix(ProjectSummaryPromptBuilder.maxParticipants)
            .map { participant in
                ProjectSummaryParticipant(
                    name: nonEmpty(participant.displayName) ?? participant.email,
                    email: participant.email,
                    messageCount: participant.messageCount
                )
            }

        return ProjectSummaryInput(
            accountID: SummarizationAccountResolver.singleAccountID(
                in: row.messageIDs.map { messageInputs[$0]?.accountID }
            ),
            projectLabel: row.displayLabel,
            statusLabel: statusLabel(row.status),
            firstActivityAt: row.firstActivityAt,
            lastActivityAt: row.lastActivityAt,
            totalMessageCount: row.messageIDs.count,
            participants: participants,
            obligations: obligations,
            deadlines: deadlines,
            digests: digests,
            userIdentity: userIdentity
        )
    }

    // MARK: - Sampling

    /// Picks up to `limit` message ids that represent the project: the
    /// earliest two (origin), the latest three (recent), every priority
    /// (obligation/deadline) id, and an even spread across the remainder.
    /// Result is returned in chronological order so the prompt reads
    /// oldest → newest.
    static func selectSampleIDs(
        ordered: [UUID],
        priority: Set<UUID>,
        limit: Int
    ) -> [UUID] {
        guard ordered.count > limit else { return ordered }
        let limit = max(1, limit)
        let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        var chosen = Set<UUID>()

        func add(_ id: UUID) {
            guard chosen.count < limit else { return }
            chosen.insert(id)
        }

        // Origin (oldest two).
        for id in ordered.prefix(2) { add(id) }
        // Recent (newest three) — most load-bearing for current state / open issue.
        for id in ordered.suffix(3) { add(id) }
        // Priority obligation/deadline-bearing messages, newest first.
        for id in ordered.reversed() where priority.contains(id) { add(id) }
        // Even spread across the remainder to fill any leftover slots.
        if chosen.count < limit, ordered.count > 1 {
            let slots = limit - chosen.count
            let stride = max(1, ordered.count / max(1, slots + 1))
            var index = stride
            while index < ordered.count, chosen.count < limit {
                add(ordered[index])
                index += stride
            }
            // Backfill deterministically if rounding left gaps.
            var fill = 0
            while chosen.count < limit, fill < ordered.count {
                add(ordered[fill])
                fill += 1
            }
        }

        return chosen.sorted { (position[$0] ?? 0) < (position[$1] ?? 0) }
    }

    // MARK: - Label helpers

    private static func obligationKindLabel(_ kind: ProjectOpenObligation.Kind) -> String {
        switch kind {
        case .pendingReply: return "awaiting your reply"
        case .confirmation: return "awaiting confirmation"
        }
    }

    private static func statusLabel(_ status: ProjectRowStatus) -> String {
        switch status {
        case .active: return "active"
        case .revived: return "revived after a quiet period"
        case .quiet: return "quiet"
        case .resolved: return "resolved"
        case .longTail: return "long-tail / winding down"
        }
    }

    // MARK: - Row helpers

    private static func senderDisplay(input: ProjectMessageInput) -> String {
        if let name = input.fromName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return input.fromAddress
    }

    private static func recipients(input: ProjectMessageInput) -> SummarizationContext.AnchorRecipients? {
        let to = input.participants.filter { $0.role == .to }.map {
            SummarizationContext.Recipient(displayName: $0.displayName, address: $0.email)
        }
        let cc = input.participants.filter { $0.role == .cc }.map {
            SummarizationContext.Recipient(displayName: $0.displayName, address: $0.email)
        }
        let recipients = SummarizationContext.AnchorRecipients(to: to, cc: cc)
        return recipients.isUseful ? recipients : nil
    }

    /// Oldest-first ordering with undated items sorted last and a stable UUID
    /// tiebreaker so the sample is deterministic across rebuilds.
    private static func chronology(_ lhs: Date?, _ rhs: Date?, _ lhsID: UUID, _ rhsID: UUID) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?) where l != r: return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhsID.uuidString < rhsID.uuidString
        }
    }

    private static func collapse(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
