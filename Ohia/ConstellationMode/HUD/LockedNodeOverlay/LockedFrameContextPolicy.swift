import Foundation
import OhiaCore
import OhiaML

/// Frame-specific neighbour policy for the locked-node overlay.
///
/// The regular semantic neighbour graph answers "what reads like this?".
/// That is exactly right in the Meaning frame, but it leaks noise in frames
/// whose question is narrower. This policy applies a hard frame predicate
/// first, then a small confidence score so related panes and CONTEXT evidence
/// only surface context that belongs to the active lens.
enum LockedFrameContextPolicy {
    struct Candidate: Sendable, Equatable {
        let messageId: String
        let score: Float
        let rankDate: Date?
    }

    nonisolated static func usesSemanticNeighbours(for frame: FrameKey) -> Bool {
        switch frame.spatialLens {
        case .meaning, .defaultFrame:
            return true
        default:
            return false
        }
    }

    nonisolated static func contextThreshold(for frame: FrameKey) -> Float? {
        switch frame.spatialLens {
        case .meaning, .defaultFrame:
            return LockedNeighborhoodResolver.QualityGate.default.absoluteFloor
        case .people:
            return 0.80
        case .projects:
            return 0.72
        default:
            return LockedNeighborhoodResolver.QualityGate.default.absoluteFloor
        }
    }

    nonisolated static func candidates(
        for frame: FrameKey,
        centerMessageId: String,
        centerRow: MessageFilterRow,
        messageIndex: [String: MessageFilterRow],
        userAddresses: Set<String>,
        limit: Int
    ) -> [Candidate] {
        guard limit > 0 else { return [] }
        let candidates: [Candidate]
        switch frame.spatialLens {
        case .meaning, .defaultFrame:
            candidates = []
        case .people:
            candidates = peopleCandidates(
                centerMessageId: centerMessageId,
                centerRow: centerRow,
                messageIndex: messageIndex,
                userAddresses: userAddresses
            )
        case .projects:
            candidates = projectCandidates(
                centerMessageId: centerMessageId,
                centerRow: centerRow,
                messageIndex: messageIndex
            )
        default:
            candidates = []
        }

        guard let threshold = contextThreshold(for: frame) else {
            return Array(candidates.prefix(limit))
        }
        return Array(
            candidates
                .filter { $0.score >= threshold }
                .sorted(by: candidateSort(centerDate: centerRow.receivedAt))
                .prefix(limit)
        )
    }

    nonisolated static func correspondentSet(
        row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> Set<String> {
        let rawAddresses: [String]
        if row.isSentByUser {
            rawAddresses = row.recipientAddresses
        } else {
            rawAddresses = [row.fromAddress]
        }

        var addresses: Set<String> = []
        for raw in rawAddresses {
            let value = normalizedEmail(raw)
            if !value.isEmpty, !userAddresses.contains(value) {
                addresses.insert(value)
            }
        }
        return addresses
    }

    nonisolated static func peopleParticipantSet(
        row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> Set<String> {
        let rawAddresses = row.isSentByUser
            ? row.recipientAddresses
            : [row.fromAddress] + row.recipientAddresses

        var addresses: Set<String> = []
        for raw in rawAddresses {
            let value = normalizedEmail(raw)
            if !value.isEmpty, !userAddresses.contains(value) {
                addresses.insert(value)
            }
        }
        return addresses
    }

    nonisolated static func peopleCandidates(
        focusedEmail rawEmail: String,
        allowedMessageIds: Set<String>,
        centerMessageId: String,
        centerRow: MessageFilterRow,
        messageIndex: [String: MessageFilterRow],
        userAddresses: Set<String>,
        limit: Int?
    ) -> [Candidate] {
        let email = normalizedEmail(rawEmail)
        guard !email.isEmpty, !allowedMessageIds.isEmpty else { return [] }

        let candidates = messageIndex.compactMap { messageId, row -> Candidate? in
            guard messageId != centerMessageId else { return nil }
            guard allowedMessageIds.contains(messageId) else { return nil }
            guard peopleParticipantSet(row: row, userAddresses: userAddresses).contains(email) else {
                return nil
            }

            var score: Float = 0.86
            score += 0.08 * temporalProximity(centerRow.receivedAt, row.receivedAt, windowDays: 180)
            if row.isSentByUser != centerRow.isSentByUser { score += 0.04 }
            if sharesSpecificPurpose(centerRow, row) { score += 0.03 }
            return Candidate(messageId: messageId, score: min(1, score), rankDate: row.receivedAt)
        }
        .sorted(by: candidateSort(centerDate: centerRow.receivedAt))

        if let limit {
            return Array(candidates.prefix(limit))
        }
        return candidates
    }

    private nonisolated static func peopleCandidates(
        centerMessageId: String,
        centerRow: MessageFilterRow,
        messageIndex: [String: MessageFilterRow],
        userAddresses: Set<String>
    ) -> [Candidate] {
        let centerCorrespondents = correspondentSet(row: centerRow, userAddresses: userAddresses)
        guard !centerCorrespondents.isEmpty else { return [] }

        return messageIndex.compactMap { messageId, row in
            guard messageId != centerMessageId else { return nil }
            let rowCorrespondents = correspondentSet(row: row, userAddresses: userAddresses)
            guard !centerCorrespondents.isDisjoint(with: rowCorrespondents) else {
                return nil
            }
            var score: Float = 0.82
            score += 0.10 * temporalProximity(centerRow.receivedAt, row.receivedAt, windowDays: 180)
            if sharesSpecificPurpose(centerRow, row) { score += 0.05 }
            if centerRow.isSentByUser != row.isSentByUser { score += 0.03 }
            return Candidate(messageId: messageId, score: min(1, score), rankDate: row.receivedAt)
        }
    }

    private nonisolated static func projectCandidates(
        centerMessageId: String,
        centerRow: MessageFilterRow,
        messageIndex: [String: MessageFilterRow]
    ) -> [Candidate] {
        let centerSignals = projectSignals(in: centerRow.dimensions)
        guard !centerSignals.isEmpty else { return [] }

        return messageIndex.compactMap { messageId, row in
            guard messageId != centerMessageId else { return nil }
            let score = projectOverlapScore(center: centerSignals, row: row)
            guard score > 0 else { return nil }
            return Candidate(messageId: messageId, score: score, rankDate: row.receivedAt)
        }
    }

    private struct ProjectSignal: Sendable {
        let tagID: UUID
        let score: Float
    }

    private nonisolated static func projectSignals(in dimensions: MessageDimensions?) -> [ProjectSignal] {
        guard let dimensions else { return [] }
        return projectSignals(tags: dimensions.semanticTags)
    }

    private nonisolated static func projectSignals(
        tags: [SemanticTagProjection]
    ) -> [ProjectSignal] {
        SemanticTagProjectionPresentation.canonical(tags)
            .filter { $0.score >= 0.25 }
            .map { tag in
                ProjectSignal(
                    tagID: tag.tagID,
                    score: max(0, min(1, Float(tag.weightedScore)))
                )
            }
    }

    private nonisolated static func projectOverlapScore(
        center: [ProjectSignal],
        row: MessageFilterRow
    ) -> Float {
        let rowSignals = projectSignals(in: row.dimensions)
        guard !rowSignals.isEmpty else { return 0 }

        var best: Float = 0
        for lhs in center {
            for rhs in rowSignals
            where lhs.tagID == rhs.tagID {
                let confidence = min(lhs.score, rhs.score)
                let score = 0.76 + 0.24 * confidence
                best = max(best, min(1, score))
            }
        }
        return best
    }

    private nonisolated static func sharesSpecificPurpose(_ lhs: MessageFilterRow, _ rhs: MessageFilterRow) -> Bool {
        guard let left = lhs.purpose,
              let right = rhs.purpose,
              left != .correspondence,
              left != .other else {
            return false
        }
        return left == right
    }

    private nonisolated static func temporalProximity(_ lhs: Date?, _ rhs: Date?, windowDays: Double) -> Float {
        guard let lhs, let rhs, windowDays > 0 else { return 0 }
        let window = windowDays * 86_400
        let delta = abs(lhs.timeIntervalSince(rhs))
        guard delta <= window else { return 0 }
        return Float(1 - delta / window)
    }

    private nonisolated static func candidateSort(centerDate: Date?) -> (Candidate, Candidate) -> Bool {
        { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if let centerDate,
               let leftDate = lhs.rankDate,
               let rightDate = rhs.rankDate {
                let leftDelta = abs(leftDate.timeIntervalSince(centerDate))
                let rightDelta = abs(rightDate.timeIntervalSince(centerDate))
                if leftDelta != rightDelta { return leftDelta < rightDelta }
            } else if lhs.rankDate != rhs.rankDate {
                return (lhs.rankDate ?? .distantPast) > (rhs.rankDate ?? .distantPast)
            }
            return lhs.messageId < rhs.messageId
        }
    }

    private nonisolated static func normalizedEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private nonisolated static func normalizedLabel(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}
