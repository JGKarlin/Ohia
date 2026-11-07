import Foundation
import OhiaCore
import OhiaIngest
import OhiaML

/// Builds the `ContextOrientationInput` consumed by `ContextOrientationService`
/// from the data the locked-node loader has already gathered. Pure / value-only
/// so the heavy SwiftData fetches stay where they belong (in `LockedNodeContextLoader`).
enum LockOrientationInputBuilder {
    /// Lower-cased excerpt cap so neighbour / thread-sibling lines don't blow
    /// past the prompt's per-item character budget. The OhiaML side enforces a
    /// stricter cap when assembling the prompt; this keeps the upstream
    /// payload roughly the right size before the prompt builder trims further.
    private static let excerptCap = 320
    private static let bodyExcerptCap = 1200

    @MainActor
    static func build(
        anchorRow: MessageFilterRow,
        bodyContent: LockReadoutBodyContent?,
        ownChunks: [LockedNodeContext.OwnChunk],
        neighbours: [LockedNodeContext.Neighbour],
        threadSiblings: [LockedNodeContext.ThreadSibling],
        attachments: [ContextOrientationAttachment],
        telemetry: SurveyTelemetry,
        activeFrame: FrameKey = .defaultFrame,
        userIdentity: SummarizationUserIdentity? = nil,
        anchorDirection: SummarizationContext.AnchorDirection? = nil
    ) -> ContextOrientationInput {
        let includeAttachmentEvidence = activeFrame.spatialLens != .meaning
        let orientationOwnChunks = includeAttachmentEvidence
            ? ownChunks
            : ownChunks.filter { $0.collection != .attachment }
        let orientationAttachments = includeAttachmentEvidence ? attachments : []
        let bodyExcerpt = Self.excerpt(from: bodyContent, cap: bodyExcerptCap)
        let ownExcerpts = orientationOwnChunks.compactMap { chunk -> ContextOrientationOwnExcerpt? in
            let trimmed = Self.collapse(chunk.textPayload).prefix(excerptCap)
            guard !trimmed.isEmpty else { return nil }
            return ContextOrientationOwnExcerpt(
                collection: collectionLabel(chunk.collection),
                excerpt: String(trimmed),
                citationTargetID: citationTargetID(for: chunk)
            )
        }

        let orientationNeighbours = Self.orientationNeighbours(
            anchorRow: anchorRow,
            bodyExcerpt: bodyExcerpt,
            ownChunks: orientationOwnChunks,
            neighbours: neighbours,
            activeFrame: activeFrame
        )
        let neighbourEntries = orientationNeighbours.map { neighbour -> ContextOrientationRelative in
            ContextOrientationRelative(
                role: neighbour.row.isSentByUser ? "outgoing" : "incoming",
                senderName: senderDisplay(row: neighbour.row),
                subject: neighbour.row.subject,
                excerpt: relativeExcerpt(
                    row: neighbour.row,
                    preferredSummary: includeAttachmentEvidence ? neighbour.matchedChunkSummary : nil,
                    allowAttachmentSummary: includeAttachmentEvidence
                ),
                receivedAt: neighbour.row.receivedAt,
                similarity: neighbour.bestSimilarity,
                direction: neighbour.row.isSentByUser ? .outgoing : .incoming,
                recipients: recipients(row: neighbour.row),
                citationTargetID: "neighbor:\(neighbour.messageId)"
            )
        }

        let threadEntries = threadSiblings.sorted { $0.position < $1.position }.map { sibling -> ContextOrientationRelative in
            let role: String
            switch sibling.position {
            case ..<0: role = sibling.isSentByUser ? "earlier (you)" : "earlier"
            case 0: role = "current"
            default: role = sibling.isSentByUser ? "later (you)" : "later"
            }
            return ContextOrientationRelative(
                role: role,
                senderName: senderDisplay(row: sibling.row),
                subject: sibling.row.subject,
                excerpt: relativeExcerpt(
                    row: sibling.row,
                    allowAttachmentSummary: includeAttachmentEvidence
                ),
                receivedAt: sibling.receivedAt ?? sibling.row.receivedAt,
                similarity: nil,
                direction: sibling.isSentByUser ? .outgoing : .incoming,
                recipients: recipients(row: sibling.row),
                citationTargetID: "thread:\(sibling.messageId)"
            )
        }

        let breakdown = anchorRow.vectorBreakdown
        return ContextOrientationInput(
            anchorSubject: anchorRow.subject,
            anchorSenderName: senderDisplay(row: anchorRow),
            anchorReceivedAt: anchorRow.receivedAt,
            anchorPurpose: anchorRow.purpose,
            bodyExcerpt: bodyExcerpt,
            ownExcerpts: ownExcerpts,
            neighbours: neighbourEntries,
            threadSiblings: threadEntries,
            attachments: orientationAttachments,
            neighbourCount: telemetry.contextNeighborCount,
            bodyVectorCount: breakdown.context,
            entityVectorCount: breakdown.entity,
            userIdentity: userIdentity,
            anchorDirection: anchorDirection,
            anchorRecipients: recipients(row: anchorRow)
        )
    }

    @MainActor
    static func buildCorrespondentRelationship(
        personFocus: LockedPersonFocus,
        historyRows: [(messageId: String, row: MessageFilterRow)],
        telemetry: SurveyTelemetry,
        memoryNotes: [ContextOrientationMemoryNote],
        userIdentity: SummarizationUserIdentity? = nil
    ) -> ContextOrientationInput {
        let focusEmail = normalizedEmail(personFocus.email)
        let rows = dedupedHistoryRows(historyRows)
        let counts = relationshipCounts(
            rows: rows.map { $0.row },
            focusedEmail: focusEmail,
            report: telemetry.threadReport
        )
        let displayName = personFocus.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let relationship = ContextOrientationCorrespondentRelationship(
            displayName: displayName.isEmpty ? personFocus.email : displayName,
            email: focusEmail.isEmpty ? personFocus.email : focusEmail,
            correspondentAuthoredCount: counts.correspondentAuthored,
            accountOwnerAuthoredCount: counts.accountOwnerAuthored,
            includedCount: counts.included,
            threadCount: counts.threadCount,
            firstCorrespondenceAt: counts.firstDate,
            lastCorrespondenceAt: counts.lastDate,
            tagSignals: dominantTagSignals(rows.map { $0.row })
        )
        let history = rows.map { entry in
            ContextOrientationRelative(
                role: relationshipRole(
                    row: entry.row,
                    focusedEmail: focusEmail,
                    focusedDisplayName: relationship.displayName
                ),
                senderName: senderDisplay(row: entry.row),
                subject: entry.row.subject,
                excerpt: relationshipExcerpt(row: entry.row),
                receivedAt: entry.row.receivedAt,
                similarity: nil,
                direction: nil,
                recipients: recipients(row: entry.row),
                citationTargetID: "message:\(entry.messageId)"
            )
        }

        return ContextOrientationInput(
            anchorSubject: "Correspondence with \(relationship.displayName)",
            anchorSenderName: relationship.displayName,
            anchorReceivedAt: counts.lastDate,
            anchorPurpose: nil,
            bodyExcerpt: "",
            ownExcerpts: [],
            neighbours: [],
            threadSiblings: history,
            attachments: [],
            neighbourCount: rows.count,
            bodyVectorCount: 0,
            entityVectorCount: 0,
            userIdentity: userIdentity,
            anchorDirection: nil,
            anchorRecipients: nil,
            subject: .correspondentRelationship(relationship),
            memoryNotes: memoryNotes
        )
    }

    /// Pulls a `ContextOrientationAttachment` per inline attachment surfaced by
    /// the locked context's own chunks. Each attachment is kept once even if
    /// it appears in multiple chunks (e.g. multi-page PDF OCR). Filtered to
    /// *text-bearing document* attachments — PDFs, RTF, plain/markdown text,
    /// Office docs, spreadsheets, presentations — so binary-only attachments
    /// (zip, video, audio with no transcript) and non-document images don't
    /// dilute the orientation prompt's attention. Non-document attachments
    /// still appear in the FILES section of the lock view; they just don't
    /// participate in the generated paragraph.
    static func attachmentsFromOwnChunks(_ chunks: [LockedNodeContext.OwnChunk]) -> [ContextOrientationAttachment] {
        var seen = Set<UUID>()
        var attachments: [ContextOrientationAttachment] = []
        for chunk in chunks {
            guard let attachment = chunk.attachment else { continue }
            guard seen.insert(attachment.id).inserted else { continue }
            guard AttachmentExtractor.isTextBearingDocument(
                mimeType: attachment.mimeType,
                filename: attachment.filename
            ) else { continue }
            attachments.append(
                ContextOrientationAttachment(
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    sizeBytes: attachment.sizeBytes,
                    citationTargetID: "attachment:\(attachment.id.uuidString)"
                )
            )
        }
        return attachments
    }

    private static func senderDisplay(row: MessageFilterRow) -> String {
        if let name = row.fromName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return row.fromAddress
    }

    private static func recipients(row: MessageFilterRow) -> SummarizationContext.AnchorRecipients? {
        let to = row.toAddresses.enumerated().map { index, address in
            let displayName = row.toDisplayNames.indices.contains(index)
                ? row.toDisplayNames[index]
                : nil
            return SummarizationContext.Recipient(displayName: displayName, address: address)
        }
        let recipients = SummarizationContext.AnchorRecipients(to: to)
        return recipients.isUseful ? recipients : nil
    }

    private static func dedupedHistoryRows(
        _ entries: [(messageId: String, row: MessageFilterRow)]
    ) -> [(messageId: String, row: MessageFilterRow)] {
        var seen = Set<String>()
        return entries
            .filter { entry in
                seen.insert(entry.messageId).inserted
            }
            .sorted { lhs, rhs in
                switch (lhs.row.receivedAt, rhs.row.receivedAt) {
                case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                    return lhsDate < rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.row.subject.localizedStandardCompare(rhs.row.subject) == .orderedAscending
                }
            }
    }

    private static func relationshipCounts(
        rows: [MessageFilterRow],
        focusedEmail: String,
        report: SurveyTelemetryThreadReport
    ) -> (
        correspondentAuthored: Int,
        accountOwnerAuthored: Int,
        included: Int,
        threadCount: Int,
        firstDate: Date?,
        lastDate: Date?
    ) {
        var correspondentAuthored = 0
        var accountOwnerAuthored = 0
        var included = 0
        var threadKeys = Set<String>()
        var firstDate: Date?
        var lastDate: Date?
        for row in rows {
            let recipients = recipientSet(row: row)
            if row.isSentByUser {
                if focusedEmail.isEmpty || recipients.contains(focusedEmail) {
                    accountOwnerAuthored += 1
                }
            } else {
                let senderMatches = normalizedEmail(row.fromAddress) == focusedEmail
                if senderMatches {
                    correspondentAuthored += 1
                } else if focusedEmail.isEmpty || recipients.contains(focusedEmail) {
                    included += 1
                }
            }
            if let threadId = row.threadId {
                threadKeys.insert(threadId.uuidString)
            } else {
                threadKeys.insert(normalizedSubjectKey(row.subject))
            }
            if let date = row.receivedAt {
                if firstDate == nil || date < firstDate! { firstDate = date }
                if lastDate == nil || date > lastDate! { lastDate = date }
            }
        }
        if report.style == .people {
            return (
                correspondentAuthored: report.totalCount,
                accountOwnerAuthored: report.userReplyCount,
                included: report.includedCount,
                threadCount: report.threadCount ?? threadKeys.count,
                firstDate: report.firstMessageAt ?? firstDate,
                lastDate: report.lastMessageAt ?? lastDate
            )
        }
        return (
            correspondentAuthored: correspondentAuthored,
            accountOwnerAuthored: accountOwnerAuthored,
            included: included,
            threadCount: threadKeys.count,
            firstDate: firstDate,
            lastDate: lastDate
        )
    }

    private static func relationshipRole(
        row: MessageFilterRow,
        focusedEmail: String,
        focusedDisplayName: String
    ) -> String {
        let name = focusedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? focusedEmail
            : focusedDisplayName
        if row.isSentByUser {
            return "account owner wrote to \(name)"
        }
        if normalizedEmail(row.fromAddress) == focusedEmail {
            return "\(name) wrote to account owner"
        }
        return "\(senderDisplay(row: row)) wrote with \(name) included"
    }

    private static func relationshipExcerpt(row: MessageFilterRow) -> String {
        relativeExcerpt(row: row, allowAttachmentSummary: false)
    }

    private static func relativeExcerpt(
        row: MessageFilterRow,
        preferredSummary: String? = nil,
        allowAttachmentSummary: Bool
    ) -> String {
        let preferred = allowAttachmentSummary ? collapse(preferredSummary ?? "") : ""
        if !preferred.isEmpty { return preferred }
        if allowAttachmentSummary || !row.hasAttachments {
            let summary = collapse(row.bodySummary ?? "")
            if !summary.isEmpty { return summary }
        }
        let tagSignals = dominantTagSignals([row])
        if !tagSignals.isEmpty {
            return "Tag signals: \(tagSignals.joined(separator: ", "))"
        }
        return row.subject
    }

    private static func dominantTagSignals(_ rows: [MessageFilterRow]) -> [String] {
        accumulatedLabels(
            rows.compactMap(\.dimensions).flatMap { dimensions in
                SemanticTagProjectionPresentation.canonical(dimensions.semanticTags).map { tag in
                    (
                        text: tag.displayName,
                        score: tag.weightedScore
                    )
                }
            },
            limit: 6
        )
    }

    private nonisolated static func accumulatedLabels(
        _ labels: [(text: String, score: Double)],
        limit: Int
    ) -> [String] {
        var scores: [String: Double] = [:]
        for label in labels {
            let text = label.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  text.localizedCaseInsensitiveCompare("unknown") != .orderedSame,
                  label.score >= 0.10 else {
                continue
            }
            scores[text, default: 0] += label.score
        }
        return scores
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .prefix(limit)
            .map(\.key)
    }

    private nonisolated static func recipientSet(row: MessageFilterRow) -> Set<String> {
        Set(row.recipientAddresses.map(normalizedEmail).filter { !$0.isEmpty })
    }

    private nonisolated static func normalizedEmail(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mailto:") {
            trimmed.removeFirst("mailto:".count)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
    }

    private nonisolated static func normalizedSubjectKey(_ subject: String) -> String {
        var working = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var changed = true
        while changed {
            changed = false
            for prefix in ["re:", "fw:", "fwd:"] where working.hasPrefix(prefix) {
                working = String(working.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return working.isEmpty ? "<empty-subject>" : working
    }

    private static func collapse(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func orientationNeighbours(
        anchorRow: MessageFilterRow,
        bodyExcerpt: String,
        ownChunks: [LockedNodeContext.OwnChunk],
        neighbours: [LockedNodeContext.Neighbour],
        activeFrame: FrameKey
    ) -> [LockedNodeContext.Neighbour] {
        switch activeFrame.spatialLens {
        case .meaning, .defaultFrame:
            break
        case .people:
            return neighbours.filter { $0.relation == .sameCorrespondent }
        case .projects:
            // These neighbours were selected by hard frame predicates in
            // `LockedFrameContextPolicy`, so a cross-correspondent semantic
            // token check would incorrectly discard valid frame context.
            // `.timeline` is intentionally absent — that lens no longer
            // mounts the locked-node overlay (NLE workspace replaces it).
            return neighbours
        default:
            break
        }

        let anchorTokens = topicTokens(
            in: ([anchorRow.subject, bodyExcerpt] + ownChunks.map { semanticEvidenceText(from: $0.textPayload) })
                .joined(separator: " ")
        )

        return neighbours.filter { neighbour in
            switch neighbour.relation {
            case .sameCorrespondent:
                return true
            case .differentCorrespondent:
                return isGroundedCrossCorrespondentNeighbour(
                    anchorRow: anchorRow,
                    anchorTokens: anchorTokens,
                    neighbour: neighbour
                )
            }
        }
    }

    private static func isGroundedCrossCorrespondentNeighbour(
        anchorRow: MessageFilterRow,
        anchorTokens: Set<String>,
        neighbour: LockedNodeContext.Neighbour
    ) -> Bool {
        if sharesSpecificSenderDomain(anchorRow, neighbour.row),
           neighbour.bestSimilarity >= 0.88 {
            return true
        }

        guard neighbour.bestSimilarity >= 0.90,
              !anchorTokens.isEmpty else {
            return false
        }

        let neighbourTokens = topicTokens(
            in: [
                neighbour.row.subject,
                neighbour.row.bodySummary ?? ""
            ].joined(separator: " ")
        )
        let overlap = anchorTokens.intersection(neighbourTokens)
        return overlap.count >= 2 || overlap.contains { $0.count >= 7 }
    }

    private static func semanticEvidenceText(from payload: String) -> String {
        payload
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let upper = line.uppercased()
                return !metadataLinePrefixes.contains { upper.hasPrefix($0) }
            }
            .joined(separator: " ")
    }

    private static func topicTokens(in text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { token in
                    token.count >= 4
                        && token.rangeOfCharacter(from: .decimalDigits.inverted) != nil
                        && !topicStopWords.contains(token)
                }
        )
    }

    private static func sharesSpecificSenderDomain(_ lhs: MessageFilterRow, _ rhs: MessageFilterRow) -> Bool {
        guard let left = senderDomain(lhs.fromAddress),
              let right = senderDomain(rhs.fromAddress),
              left == right,
              !genericMailDomains.contains(left) else {
            return false
        }
        return true
    }

    private static func senderDomain(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let domain = String(trimmed[trimmed.index(after: at)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'").union(.whitespacesAndNewlines))
        return domain.isEmpty ? nil : domain
    }

    private static let topicStopWords: Set<String> = [
        "about", "account", "after", "also", "another", "before", "being", "between",
        "booking", "confirmation", "could", "email", "from", "have", "into", "invoice",
        "item", "latest", "mail", "message", "more", "most", "near", "newsletter",
        "note", "notice", "notification", "only", "order", "other", "over", "payment",
        "please", "prior", "receipt", "reservation", "same", "security", "sent",
        "service", "shared", "statement", "subject", "subscription", "than", "that",
        "their", "there", "these", "this", "through", "update", "using", "what",
        "when", "where", "which", "with", "would", "your"
    ]

    private static let metadataLinePrefixes: Set<String> = [
        "ATTACHMENTS:",
        "DATE_BUCKET:",
        "FROM:",
        "LANGUAGE:",
        "SUBJECT:",
        "TO:"
    ]

    private static let genericMailDomains: Set<String> = [
        "aol.com", "gmail.com", "googlemail.com", "hey.com", "hotmail.com",
        "icloud.com", "live.com", "mac.com", "me.com", "msn.com", "outlook.com",
        "proton.me", "protonmail.com", "yahoo.com"
    ]

    private static func excerpt(from bodyContent: LockReadoutBodyContent?, cap: Int) -> String {
        guard let bodyContent else { return "" }
        let collapsed = collapse(bodyContent.plainText)
        guard collapsed.count > cap else { return collapsed }
        return String(collapsed.prefix(cap))
    }

    private static func collectionLabel(_ collection: VectorCollection) -> String {
        switch collection {
        case .context: return "body"
        case .attachment: return "attachment"
        case .entity: return "mention"
        case .style: return "style"
        }
    }

    private static func citationTargetID(for chunk: LockedNodeContext.OwnChunk) -> String? {
        switch chunk.collection {
        case .context, .style:
            return "vector:\(chunk.vectorId)"
        case .attachment:
            if let attachment = chunk.attachment {
                return "attachment:\(attachment.id.uuidString)"
            }
            return "vector:\(chunk.vectorId)"
        case .entity:
            if let entityKey = chunk.entityKey, !entityKey.isEmpty {
                return "entity:\(entityKey)"
            }
            return "entity:\(chunk.vectorId)"
        }
    }
}
