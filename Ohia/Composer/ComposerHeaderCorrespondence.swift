import Foundation
import OhiaCore
import OhiaML

nonisolated struct ComposerHeaderMailingListIdentity: Sendable, Equatable {
    let accountID: UUID
    let listID: String
    let displayName: String
    let postingAddress: String?
}

nonisolated struct ComposerHeaderCorrespondenceTarget: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case correspondent
        case mailingList
    }

    let kind: Kind
    let displayName: String
    let address: String
    let postingAddress: String?
    let listID: String?
}

nonisolated struct ComposerHeaderCorrespondenceHistoryItem: Sendable, Equatable {
    enum Direction: Sendable, Equatable {
        case received
        case sent
        case included
    }

    let messageID: String
    let threadID: UUID?
    let direction: Direction
    let senderName: String
    let subject: String
    let excerpt: String
    let date: Date
    let toRecipients: [MessageStoreConstellationRecipient]
    let ccRecipients: [MessageStoreConstellationRecipient]
}

nonisolated struct ComposerHeaderCorrespondenceSnapshot: Sendable, Equatable {
    let target: ComposerHeaderCorrespondenceTarget
    let receivedCount: Int
    let sentCount: Int
    let includedCount: Int
    let threadCount: Int
    let firstCorrespondenceAt: Date?
    let lastCorrespondenceAt: Date?
    let history: [ComposerHeaderCorrespondenceHistoryItem]

    var hasHistory: Bool {
        !history.isEmpty
    }
}

/// Pure correspondence selection and presentation logic for the new-message
/// Composer header. The UI owns lifecycle and model-generation state; this
/// builder keeps account/list matching and prompt evidence deterministic.
nonisolated enum ComposerHeaderCorrespondenceBuilder {
    private static let representativeHistoryLimit = 8

    static func target(
        recipients: [ComposeAddressEncoding.ParsedAddress],
        accountID: UUID?,
        mailingLists: [ComposerHeaderMailingListIdentity]
    ) -> ComposerHeaderCorrespondenceTarget? {
        guard let recipient = recipients.first else { return nil }
        let address = normalizedAddress(recipient.asciiAddress)
        guard !address.isEmpty else { return nil }

        if let accountID,
           let list = mailingLists.first(where: {
               $0.accountID == accountID && mailingList($0, matchesPostingAddress: address)
           }) {
            let listName = collapsed(list.displayName)
            return ComposerHeaderCorrespondenceTarget(
                kind: .mailingList,
                displayName: listName.isEmpty ? address : listName,
                address: address,
                postingAddress: normalizedOptionalAddress(list.postingAddress) ?? address,
                listID: normalizedListID(list.listID)
            )
        }

        let recipientName = collapsed(recipient.displayName ?? "")
        return ComposerHeaderCorrespondenceTarget(
            kind: .correspondent,
            displayName: recipientName.isEmpty ? address : recipientName,
            address: address,
            postingAddress: nil,
            listID: nil
        )
    }

    static func loadSnapshot(
        target: ComposerHeaderCorrespondenceTarget,
        accountID: UUID?,
        storeURL: URL
    ) throws -> ComposerHeaderCorrespondenceSnapshot {
        let rows = try MessageStoreHotPath.constellationMessageRows(
            requiringCompletedEmbedding: false,
            storeURL: storeURL
        ) ?? []
        return snapshot(target: target, accountID: accountID, rows: rows)
    }

    static func snapshot(
        target: ComposerHeaderCorrespondenceTarget,
        accountID: UUID?,
        rows: [MessageStoreConstellationMessageRow]
    ) -> ComposerHeaderCorrespondenceSnapshot {
        var receivedCount = 0
        var sentCount = 0
        var includedCount = 0
        var history: [ComposerHeaderCorrespondenceHistoryItem] = []
        var threadKeys = Set<String>()

        for row in rows where accountID == nil || row.accountId == accountID {
            guard !isLocalDraftMirror(row) else { continue }
            guard let direction = direction(row: row, target: target) else { continue }
            switch direction {
            case .received: receivedCount += 1
            case .sent: sentCount += 1
            case .included: includedCount += 1
            }

            let date = eventDate(row)
            let threadKey = row.threadId?.uuidString ?? normalizedSubject(row.subject)
            threadKeys.insert(threadKey.isEmpty ? "message:\(row.messageId)" : threadKey)
            history.append(
                ComposerHeaderCorrespondenceHistoryItem(
                    messageID: row.messageId,
                    threadID: row.threadId,
                    direction: direction,
                    senderName: senderDisplay(row),
                    subject: row.subject,
                    excerpt: correspondenceExcerpt(row),
                    date: date,
                    toRecipients: row.toRecipients,
                    ccRecipients: row.ccRecipients
                )
            )
        }

        history.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.messageID < $1.messageID
        }
        let firstDate = history.first?.date
        let lastDate = history.last?.date

        return ComposerHeaderCorrespondenceSnapshot(
            target: target,
            receivedCount: receivedCount,
            sentCount: sentCount,
            includedCount: includedCount,
            threadCount: threadKeys.count,
            firstCorrespondenceAt: firstDate,
            lastCorrespondenceAt: lastDate,
            history: representativeHistory(history)
        )
    }

    static func orientationInput(
        snapshot: ComposerHeaderCorrespondenceSnapshot,
        userIdentity: SummarizationUserIdentity?,
        memoryNotes: [ContextOrientationMemoryNote]
    ) -> ContextOrientationInput {
        let target = snapshot.target
        let isList = target.kind == .mailingList
        let relationship = ContextOrientationCorrespondentRelationship(
            displayName: target.displayName,
            email: target.postingAddress ?? target.address,
            correspondentAuthoredCount: snapshot.receivedCount,
            accountOwnerAuthoredCount: snapshot.sentCount,
            includedCount: snapshot.includedCount,
            threadCount: snapshot.threadCount,
            firstCorrespondenceAt: snapshot.firstCorrespondenceAt,
            lastCorrespondenceAt: snapshot.lastCorrespondenceAt,
            tagSignals: isList ? ["Mailing list activity", "Group discussion"] : []
        )
        let history = snapshot.history.map { item in
            ContextOrientationRelative(
                role: role(item, target: target),
                senderName: item.senderName,
                subject: item.subject,
                excerpt: item.excerpt,
                receivedAt: item.date,
                similarity: nil,
                direction: item.direction == .sent ? .outgoing : .incoming,
                recipients: recipients(item),
                citationTargetID: "message:\(item.messageID)"
            )
        }

        return ContextOrientationInput(
            anchorSubject: isList
                ? "Mailing list activity: \(target.displayName)"
                : "Correspondence with \(target.displayName)",
            anchorSenderName: target.displayName,
            anchorReceivedAt: snapshot.lastCorrespondenceAt,
            anchorPurpose: nil,
            bodyExcerpt: "",
            ownExcerpts: [],
            neighbours: [],
            threadSiblings: history,
            attachments: [],
            neighbourCount: snapshot.receivedCount + snapshot.sentCount + snapshot.includedCount,
            bodyVectorCount: 0,
            entityVectorCount: 0,
            userIdentity: userIdentity,
            anchorDirection: nil,
            anchorRecipients: nil,
            subject: .correspondentRelationship(relationship),
            memoryNotes: isList ? [] : memoryNotes
        )
    }

    static func memoryNotes(
        provider: (any AskMemoryProvider)?,
        target: ComposerHeaderCorrespondenceTarget,
        accountID: UUID?
    ) -> [ContextOrientationMemoryNote] {
        guard target.kind == .correspondent, let provider else { return [] }
        do {
            let context = try provider.context(
                for: "\(target.displayName) \(target.address) correspondence history relationship status topics issues",
                filter: FilterSpec(
                    accountIds: accountID.map { [$0] } ?? [],
                    senderEmails: [target.address]
                ),
                limit: AskMemoryLimit(maxSnippets: 5, maxCharacters: 1_800)
            )
            return context.snippets
                .filter { $0.source.hasPrefix("memory:\(AccountMemoryDimension.correspondent):") }
                .map {
                    ContextOrientationMemoryNote(
                        title: $0.title,
                        text: $0.text,
                        source: $0.source,
                        score: $0.score
                    )
                }
        } catch {
            return []
        }
    }

    static func plainSummary(_ paragraph: String) -> String {
        let withoutCitations = replacing(pattern: #"\[\d+\]"#, in: paragraph, with: "")
        let withoutPunctuationGaps = replacing(
            pattern: #"\s+([,.;:!?])"#,
            in: withoutCitations,
            with: "$1"
        )
        return collapsed(withoutPunctuationGaps)
    }

    static func cacheVectorID(
        target: ComposerHeaderCorrespondenceTarget,
        accountID: UUID?
    ) -> Int64 {
        let key = [accountID?.uuidString ?? "all", target.kind == .mailingList ? "list" : "person", target.listID ?? target.address]
            .joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return -Int64(hash & 0x7fff_ffff_ffff_ffff) - 1
    }

    private static func mailingList(
        _ list: ComposerHeaderMailingListIdentity,
        matchesPostingAddress address: String
    ) -> Bool {
        if normalizedAddress(list.postingAddress ?? "") == address { return true }
        let listID = normalizedListID(list.listID)
        if listID == address { return true }
        return canonicalListID(forRecipientAddress: address) == listID
    }

    private static func direction(
        row: MessageStoreConstellationMessageRow,
        target: ComposerHeaderCorrespondenceTarget
    ) -> ComposerHeaderCorrespondenceHistoryItem.Direction? {
        let recipientSet = Set(row.recipientAddresses.map(normalizedAddress))
        switch target.kind {
        case .mailingList:
            if row.isSentByUser {
                let postingAddress = target.postingAddress ?? target.address
                return recipientSet.contains(postingAddress) ? .sent : nil
            }
            guard let listID = target.listID else { return nil }
            return normalizedListID(row.listId ?? "") == listID ? .received : nil

        case .correspondent:
            if row.isSentByUser {
                return recipientSet.contains(target.address) ? .sent : nil
            }
            if normalizedAddress(row.fromAddress) == target.address { return .received }
            return recipientSet.contains(target.address) ? .included : nil
        }
    }

    private static func isLocalDraftMirror(_ row: MessageStoreConstellationMessageRow) -> Bool {
        guard let messageIDHeader = row.messageIdHeader else { return false }
        let normalized = messageIDHeader
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        return normalized.hasPrefix("draft-") && normalized.hasSuffix("@ohia.local")
    }

    private static func eventDate(_ row: MessageStoreConstellationMessageRow) -> Date {
        if row.isSentByUser {
            return row.sentAt ?? row.receivedAt ?? row.ingestedAt
        }
        return row.receivedAt ?? row.sentAt ?? row.ingestedAt
    }

    private static func representativeHistory(
        _ history: [ComposerHeaderCorrespondenceHistoryItem]
    ) -> [ComposerHeaderCorrespondenceHistoryItem] {
        guard history.count > representativeHistoryLimit else { return history }
        let edgeCount = representativeHistoryLimit / 2
        return Array(history.prefix(edgeCount)) + Array(history.suffix(edgeCount))
    }

    private static func senderDisplay(_ row: MessageStoreConstellationMessageRow) -> String {
        let name = collapsed(row.fromName ?? "")
        return name.isEmpty ? normalizedAddress(row.fromAddress) : name
    }

    private static func correspondenceExcerpt(_ row: MessageStoreConstellationMessageRow) -> String {
        let summary = collapsed(row.bodySummary ?? "")
        return summary.isEmpty ? collapsed(row.subject) : summary
    }

    private static func role(
        _ item: ComposerHeaderCorrespondenceHistoryItem,
        target: ComposerHeaderCorrespondenceTarget
    ) -> String {
        if target.kind == .mailingList {
            return item.direction == .sent
                ? "account owner wrote to \(target.displayName)"
                : "\(item.senderName) posted to \(target.displayName)"
        }
        switch item.direction {
        case .received:
            return "\(target.displayName) wrote to account owner"
        case .sent:
            return "account owner wrote to \(target.displayName)"
        case .included:
            return "\(item.senderName) wrote with \(target.displayName) included"
        }
    }

    private static func recipients(
        _ item: ComposerHeaderCorrespondenceHistoryItem
    ) -> SummarizationContext.AnchorRecipients? {
        let to = item.toRecipients.map {
            SummarizationContext.Recipient(displayName: $0.displayName, address: $0.emailAddress)
        }
        let cc = item.ccRecipients.map {
            SummarizationContext.Recipient(displayName: $0.displayName, address: $0.emailAddress)
        }
        let recipients = SummarizationContext.AnchorRecipients(to: to, cc: cc)
        return recipients.isUseful ? recipients : nil
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedOptionalAddress(_ address: String?) -> String? {
        guard let address else { return nil }
        let normalized = normalizedAddress(address)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedListID(_ listID: String) -> String {
        listID
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> ").union(.whitespacesAndNewlines))
            .lowercased()
    }

    private static func canonicalListID(forRecipientAddress address: String) -> String? {
        let parts = normalizedAddress(address).split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    private static func normalizedSubject(_ subject: String) -> String {
        var value = collapsed(subject).lowercased()
        while true {
            let prefixes = ["re:", "fw:", "fwd:"]
            guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else { break }
            value = collapsed(String(value.dropFirst(prefix.count)))
        }
        return value
    }

    private static func collapsed(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(
        pattern: String,
        in text: String,
        with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
